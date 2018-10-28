{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE ViewPatterns        #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE TypeApplications    #-}

-- | 'Symbolic' allocation of quantified variables for arguments and tags,
-- for use prior to evaluation; and functions to saturate and show models from
-- Z3 post-evaluation.
module Pact.Analyze.Model.Tags
  ( allocArgs
  , allocModelTags
  , saturateModel
  ) where

import GHC.Stack

import Data.Type.Equality ((:~:)(Refl))
import           Control.Lens         (Traversal', toListOf, traverseOf,
                                       traversed, (<&>), (?~), (^.), _1, _2, _3)
import           Control.Monad        (when, (>=>))
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict      as Map
import           Data.SBV             (SBV, SymWord, Symbolic)
import qualified Data.SBV             as SBV
import qualified Data.SBV.Control     as SBV
import qualified Data.SBV.Internals   as SBVI
import           Data.Traversable     (for)

import qualified Pact.Types.Typecheck as TC

import           Pact.Analyze.Types

alloc :: SymWord a => Symbolic (SBV a)
alloc = SBV.free_

allocSchema :: HasCallStack => Schema -> Symbolic Object
allocSchema (Schema fieldTys) = Object <$>
  for fieldTys (\ety -> (ety,) <$> allocAVal ety)

allocAVal :: HasCallStack => EType -> Symbolic AVal
allocAVal = \case
  EObjectTy schema -> AnObj <$> allocSchema schema

  EType t@(SList _ty) -> error $ show t
  EType (ty :: SingTy k ty) -> singCase ty
    (\Refl -> mkAVal . sansProv <$>
      (withSymWord ty alloc :: Symbolic (SBV (Concrete ty))))
    (\Refl -> error "this branch is not (!) impossible in the current formulation")
    (\Refl -> error "this branch is impossible in the current formulation")

allocTVal :: HasCallStack => EType -> Symbolic TVal
allocTVal ety = (ety,) <$> allocAVal ety

allocForETerm :: HasCallStack => ETerm -> Symbolic TVal
allocForETerm
  (EList (SList ty :: SingTy 'ListK ty)
  (CoreTerm (LiteralList _ cells))) = do
    cells' <- traverse
      (\_ -> mkAVal . sansProv <$>
        (withSymWord ty alloc :: Symbolic (SBV (Concrete (ListElem ty)))))
      cells
    pure (EType ty, AList cells')
allocForETerm (EList (SList ty :: SingTy 'ListK ty) b) = withShow ty $ error $ show b
allocForETerm (existentialType -> ety) = allocTVal ety

allocArgs :: HasCallStack => [Arg] -> Symbolic (Map VarId (Located (Unmunged, TVal)))
allocArgs args = fmap Map.fromList $ for args $ \(Arg nm vid node ety) -> do
  let info = node ^. TC.aId . TC.tiInfo
  av <- allocAVal ety <&> _AVal._1 ?~ FromInput nm
  pure (vid, Located info (nm, (ety, av)))

allocModelTags
  :: HasCallStack
  => Located ETerm -> ExecutionGraph -> Symbolic (ModelTags 'Symbolic)
allocModelTags locatedTm graph = ModelTags
    <$> allocVars
    <*> allocReads
    <*> allocWrites
    <*> allocAsserts
    <*> allocAuths
    <*> allocResult
    <*> allocPaths
    <*> allocReturns

  where
    -- For the purposes of symbolic value allocation, we just grab all of the
    -- events from the graph indiscriminately:
    events :: [TraceEvent]
    events = toListOf (egEdgeEvents.traverse.traverse) graph

    allocVars :: Symbolic (Map VarId (Located (Unmunged, TVal)))
    allocVars = fmap Map.fromList $
      for (toListOf (traverse._TracePushScope._3.traverse) events) $
        \(Located info (Binding vid nm _ ety)) ->
          allocTVal ety <&> \tv -> (vid, Located info (nm, tv))

    allocS :: SymWord a => Symbolic (S a)
    allocS = sansProv <$> alloc

    allocAccesses
      :: Traversal' TraceEvent (Schema, Located TagId)
      -> Symbolic (Map TagId (Located Access))
    allocAccesses p = fmap Map.fromList $
      for (toListOf (traverse.p) events) $ \(schema, Located info tid) -> do
        srk <- allocS
        obj <- allocSchema schema
        suc <- alloc
        pure (tid, Located info (Access srk obj suc))

    allocReads :: Symbolic (Map TagId (Located Access))
    allocReads = allocAccesses _TraceRead

    traceWriteT :: Traversal' TraceEvent (Schema, Located TagId)
    traceWriteT f event = case event of
      TraceWrite _writeType schema tagid -> const event <$> f (schema, tagid)
      _                                  -> pure event

    allocWrites :: Symbolic (Map TagId (Located Access))
    allocWrites = allocAccesses traceWriteT

    allocAsserts :: Symbolic (Map TagId (Located (SBV Bool)))
    allocAsserts = fmap Map.fromList $
      for (toListOf (traverse._TraceAssert._2) events) $ \(Located info tid) ->
        (tid,) . Located info <$> alloc

    allocAuths :: Symbolic (Map TagId (Located Authorization))
    allocAuths = fmap Map.fromList $
      for (toListOf (traverse._TraceAuth._2) events) $ \(Located info tid) ->
        (tid,) . Located info <$> (Authorization <$> allocS <*> alloc)

    allocResult :: Symbolic (TagId, Located TVal)
    allocResult = do
      let tid :: TagId = last $ toListOf (traverse._TracePopScope._3) events
      fmap (tid,) $ sequence $ allocForETerm <$> locatedTm

    -- NOTE: the root path we manually set to true. translation only emits the
    -- start of "subpaths" on either side of a conditional. the root path is
    -- always trivially reachable, because it corresponds to the start of a
    -- program.
    allocPaths :: Symbolic (Map Path (SBV Bool))
    allocPaths = do
      let rootPath = _egRootPath graph
          paths    = rootPath : toListOf (traverse._TraceSubpathStart) events
      fmap Map.fromList $
        for paths $ \p -> do
          sbool <- alloc
          when (p == rootPath) $ SBV.constrain sbool
          pure (p, sbool)

    allocReturns :: Symbolic (Map TagId TVal)
    allocReturns = fmap Map.fromList $
      for (toListOf (traverse._TracePopScope) events) $ \(_, _, tid, ety) ->
        (tid,) <$> allocTVal ety

-- | Builds a new 'Model' by querying the SMT model to concretize the provided
-- symbolic 'Model'.
saturateModel :: Model 'Symbolic -> SBV.Query (Model 'Concrete)
saturateModel =
    traverseOf (modelArgs.traversed.located._2)        fetchTVal   >=>
    traverseOf (modelTags.mtVars.traversed.located._2) fetchTVal   >=>
    traverseOf (modelTags.mtReads.traversed.located)   fetchAccess >=>
    traverseOf (modelTags.mtWrites.traversed.located)  fetchAccess >=>
    traverseOf (modelTags.mtAsserts.traversed.located) fetchSbv    >=>
    traverseOf (modelTags.mtAuths.traversed.located)   fetchAuth   >=>
    traverseOf (modelTags.mtResult._2.located)         fetchTVal   >=>
    traverseOf (modelTags.mtPaths.traversed)           fetchSbv    >=>
    traverseOf (modelTags.mtReturns.traversed)         fetchTVal   >=>
    traverseOf (modelKsProvs.traversed)                fetchProv

  where
    fetchTVal :: TVal -> SBV.Query TVal
    fetchTVal (ety, av) = (ety,) <$> go ety av
      where
        go :: EType -> AVal -> SBV.Query AVal
        go (EType (ty :: SingTy k t)) (AVal _mProv sval) = singCase ty
          (\Refl -> withSymWord ty $ withSMTValue ty $
            mkAVal' . SBV.literal
              <$> SBV.getValue (SBVI.SBV sval :: SBV (Concrete t)))
          (\Refl -> error "TODO")
          (\Refl -> error "TODO")

        go (EObjectTy _) (AnObj obj) = AnObj <$> fetchObject obj
        go _ _ = error "fetchTVal: impossible"

    -- NOTE: This currently rebuilds an SBV. Not sure if necessary.
    fetchSbv :: (SymWord a, SBV.SMTValue a) => SBV a -> SBV.Query (SBV a)
    fetchSbv = fmap SBV.literal . SBV.getValue

    fetchS :: (SymWord a, SBV.SMTValue a) => S a -> SBV.Query (S a)
    fetchS = traverseOf s2Sbv fetchSbv

    fetchObject :: Object -> SBVI.Query Object
    fetchObject (Object fields) = Object <$> traverse fetchTVal fields

    fetchAccess :: Access -> SBV.Query Access
    fetchAccess (Access sRk obj suc) = do
      sRk' <- fetchS sRk
      obj' <- fetchObject obj
      suc' <- fetchSbv suc
      pure $ Access sRk' obj' suc'

    fetchAuth :: Authorization -> SBV.Query Authorization
    fetchAuth (Authorization sKs sbool) = Authorization <$>
      fetchS sKs <*> fetchSbv sbool

    fetchProv :: Provenance -> SBV.Query Provenance
    fetchProv = traverseOf (_FromCell.ocRowKey) fetchS
            >=> traverseOf _FromNamedKs         fetchS
