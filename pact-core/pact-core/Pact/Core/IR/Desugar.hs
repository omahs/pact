{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE TypeApplications #-}


module Pact.Core.IR.Desugar
 ( runDesugarTermNew
 , runDesugarTopLevelNew
 , runDesugarTermLisp
 , runDesugarTopLevelLisp
 , DesugarOutput(..)
 ) where

import Control.Monad.Reader
import Control.Monad.State.Strict
import Control.Lens hiding (List,ix)
import Data.Text(Text)
import Data.Map.Strict(Map)
import Data.List(findIndex)
import Data.List.NonEmpty(NonEmpty(..))
import Data.IORef
import Data.Set(Set)
import Data.Graph(stronglyConnComp, SCC(..))
import qualified Data.Map.Strict as Map
import qualified Data.List.NonEmpty as NE
import qualified Data.Vector as V
import qualified Data.Set as Set
import qualified Data.Text as T

import Pact.Core.Builtin
import Pact.Core.Names
import Pact.Core.Type
import Pact.Core.Literal
import Pact.Core.Hash
import Pact.Core.Persistence
import Pact.Core.IR.Term

import qualified Pact.Core.Syntax.Common as Common
import qualified Pact.Core.Syntax.New.ParseTree as New
import qualified Pact.Core.Syntax.Lisp.ParseTree as Lisp
import qualified Pact.Core.Untyped.Term as Term

{- Note on Desugaring + Renaming:

  [Desugaring]
  In surface new pact core (and the lisp as well) we have "blocks",
  which are more like a sequence term `a; b`. We desugar blocks such as:
    let x1 = e1;
    let x2 = e2;
    defun f(a, b) = e3
    f1(f(x1, x2));
    f2();
  into:
    let x1 = e1 in
    let x2 = e2 in
    let f = fn (a, b) => e3 in
    {f1(f(x1, x2)), f2()}
  Moreover, `if a then b else c` gets desugared into
  `if a then () => b else () => c`

  [Renaming]
  In core, we use a locally nameless representation, and prior to the final pass,
  we use unique names for bound variables, for simplicity in the typechecker and in other passes.
  In the process of generating unique names and renaming bound locals, we also perform two other
  tasks:
    - We resolve imported names
    - We ensure the call graph in the functions declared in the module is acyclic
    If perf of stronglyConnCompR is every measured to be suboptimal, it might be
    worth writing our own.
-}


data RenamerEnv b i
  = RenamerEnv
  { _reBinds :: Map Text (IRNameKind, Unique)
  , _reSupply :: IORef Supply
  , _rePactDb :: PactDb b i
  }
makeLenses ''RenamerEnv

data RenamerState b i
  = RenamerState
  { _rsModuleBinds :: Map ModuleName (Map Text IRNameKind)
  , _rsLoaded :: Loaded b i
  , _rsDependencies :: Set ModuleName }

makeLenses ''RenamerState

newtype RenamerM cb ci a =
  RenamerT (StateT (RenamerState cb ci) (ReaderT (RenamerEnv cb ci) IO) a)
  deriving
    (Functor, Applicative, Monad
    , MonadReader (RenamerEnv cb ci)
    , MonadState (RenamerState cb ci)
    , MonadFail
    , MonadIO)
  via (StateT (RenamerState cb ci) (ReaderT (RenamerEnv cb ci) IO))

data DesugarOutput b i a
  = DesugarOutput
  { _dsOut :: a
  , _dsSupply :: Supply
  , _dsLoaded :: Loaded b i
  , _dsDeps :: Set ModuleName
  } deriving (Show, Functor)

dsOut :: Lens (DesugarOutput b i a) (DesugarOutput b i a') a a'
dsOut f (DesugarOutput a s l d) =
  f a <&> \a' -> DesugarOutput a' s l d

newUnique' :: RenamerM cb ci Unique
newUnique' = do
  sup <- view reSupply
  u <- liftIO (readIORef sup)
  liftIO (modifyIORef' sup (+ 1))
  pure u

dummyTLUnique :: Unique
dummyTLUnique = -1111

class DesugarBuiltin b where
  builtinIf :: b
  reservedNatives :: Map Text b
  desugarBinary :: Common.BinaryOp -> b
  desugarUnary :: Common.UnaryOp -> b

instance DesugarBuiltin RawBuiltin where
  reservedNatives = rawBuiltinMap
  builtinIf = RawIf
  desugarBinary = desugarBinary'
  desugarUnary = desugarUnary'

instance DesugarBuiltin (ReplBuiltin RawBuiltin) where
  reservedNatives = replRawBuiltinMap
  builtinIf = RBuiltinWrap RawIf
  desugarBinary = RBuiltinWrap . desugarBinary'
  desugarUnary = RBuiltinWrap . desugarUnary'

-- type DesugarTerm term b i = (?desugarTerm :: term -> Term ParsedName Text b i)
class DesugarTerm term b i where
  desugarTerm  :: term -> Term ParsedName b i

instance DesugarBuiltin b => DesugarTerm (New.Expr ParsedName i) b i where
  desugarTerm = desugarNewTerm

instance DesugarBuiltin b => DesugarTerm (Lisp.Expr ParsedName i) b i where
  desugarTerm = desugarLispTerm

-----------------------------------------------------------
-- Desugaring for new syntax
-----------------------------------------------------------
defunToLetNew :: Common.Defun (New.Expr ParsedName i) i -> New.Expr ParsedName i
defunToLetNew = \case
  Common.Defun defname args retTy body i ->
    let lamName = BN (BareName defname)
    in case args of
      [] ->
        let defTy = Common.TyFun Common.TyUnit retTy
            lamBody = New.Lam lamName (("#unitArg", Just Common.TyUnit):| []) body i
        in New.Let defname (Just defTy) lamBody i
      x:xs ->
        let args' = x:|xs
            defTy = foldr Common.TyFun retTy (Common._argType <$> args')
            lamArgs = (\(Common.Arg n ty) -> (n, Just ty)) <$> args'
            lamBody = New.Lam lamName lamArgs body i
        in New.Let defname (Just defTy) lamBody i


desugarNewTerm :: forall b i. DesugarBuiltin b => New.Expr ParsedName i -> Term ParsedName b i
desugarNewTerm = \case
  New.Var (BN n) i | isReservedNative (_bnName n) ->
    Builtin (reservedNatives Map.! _bnName n) i
  New.Var n i -> Var n i
  New.Block (h :| hs) _ ->
    unLetBlock h hs
  New.Let name mt expr i -> let
    name' = BN (BareName  name)
    expr' = desugarNewTerm expr
    mt' = desugarType <$> mt
    in Let name' mt' expr' (Constant LUnit i) i
  New.NestedDefun d _ ->
    desugarNewTerm (defunToLetNew d)
  New.LetIn name mt e1 e2 i -> let
    name' = BN (BareName  name)
    e1' = desugarNewTerm e1
    mt' = desugarType <$> mt
    e2' = desugarNewTerm e2
    in Let name' mt' e1' e2' i
  New.Lam _name nsts body i -> let
    (ns, ts) = NE.unzip nsts
    ns' = BN . BareName <$> ns
    ts' = fmap desugarType <$> ts
    body' = desugarNewTerm body
    in Lam (NE.zip ns' ts') body' i
  New.If cond e1 e2 i -> let
    cond' = desugarNewTerm cond
    e1' = suspend i e1
    e2' = suspend i e2
    in App (Builtin builtinIf i) (cond' :| [e1', e2']) i
  New.App e [] i -> let
    e' = desugarNewTerm e
    body = Constant LUnit i :| []
    in App e' body i
  New.App e (h:hs) i -> let
    e' = desugarNewTerm e
    h' = desugarNewTerm h
    hs' = fmap desugarNewTerm hs
    in App e' (h' :| hs') i
  New.BinaryOp bop e1 e2 i -> let
    e1' = desugarNewTerm e1
    e2' = desugarNewTerm e2
    in App (Builtin (desugarBinary bop) i) (e1' :| [e2']) i
  New.UnaryOp uop e1 i -> let
    e1' = desugarNewTerm e1
    in App (Builtin (desugarUnary uop) i) (e1' :| []) i
  New.List e1 i ->
    ListLit (V.fromList (desugarNewTerm <$> e1)) i
  New.Constant l i ->
    Constant l i
  New.Object objs i ->
    ObjectLit (desugarNewTerm <$> objs) i
  New.ObjectOp o i ->
    ObjectOp (desugarNewTerm <$> o) i
  where
  isReservedNative n =
    Map.member n (reservedNatives @b)
  suspend i e = let
    name = BN (BareName "#ifArg")
    e' = desugarNewTerm e
    in Lam ((name, Just TyUnit) :| []) e' i
  unLetBlock (New.NestedDefun d _) rest = do
    unLetBlock (defunToLetNew d) rest
  unLetBlock (New.Let name mt expr i) (h:hs) = let
    name' = BN (BareName name)
    expr' = desugarNewTerm expr
    mt' = desugarType <$> mt
    e2 = unLetBlock h hs
    in Let name' mt' expr' e2 i
  unLetBlock other l = case l of
    h:hs -> let
      other' = desugarNewTerm other
      in case unLetBlock h hs of
        Block nel' i' ->
          Block (NE.cons other' nel') i'
        t -> Block (other' :| [t]) (other' ^. termInfo)
    [] -> desugarNewTerm other

desugarLispTerm :: forall b i. DesugarBuiltin b => Lisp.Expr ParsedName i -> Term ParsedName b i
desugarLispTerm = \case
  Lisp.Var (BN n) i | isReservedNative (_bnName n) ->
    Builtin (reservedNatives Map.! _bnName n) i
  Lisp.Var n i -> Var n i
  Lisp.Block nel i ->
    Block (desugarLispTerm <$> nel) i
  Lisp.LetIn binders expr i -> let
    expr' = desugarLispTerm expr
    in foldr (binderToLet i) expr' binders
  Lisp.Lam _name nsts body i -> let
    (ns, ts) = NE.unzip nsts
    ns' = BN . BareName <$> ns
    ts' = fmap desugarType <$> ts
    body' = desugarLispTerm body
    in Lam (NE.zip ns' ts') body' i
  Lisp.If cond e1 e2 i -> let
    cond' = desugarLispTerm cond
    e1' = suspend i e1
    e2' = suspend i e2
    in App (Builtin builtinIf i) (cond' :| [e1', e2']) i
  Lisp.App e [] i -> let
    e' = desugarLispTerm e
    body = Constant LUnit i :| []
    in App e' body i
  Lisp.App e (h:hs) i -> let
    e' = desugarLispTerm e
    h' = desugarLispTerm h
    hs' = fmap desugarLispTerm hs
    in App e' (h' :| hs') i
  Lisp.BinaryOp bop e1 e2 i -> let
    e1' = desugarLispTerm e1
    e2' = desugarLispTerm e2
    in App (Builtin (desugarBinary bop) i) (e1' :| [e2']) i
  Lisp.UnaryOp uop e1 i -> let
    e1' = desugarLispTerm e1
    in App (Builtin (desugarUnary uop) i) (e1' :| []) i
  Lisp.List e1 i ->
    ListLit (V.fromList (desugarLispTerm <$> e1)) i
  Lisp.Constant l i ->
    Constant l i
  Lisp.Object objs i ->
    ObjectLit (desugarLispTerm <$> objs) i
  Lisp.ObjectOp o i ->
    ObjectOp (desugarLispTerm <$> o) i
  where
  binderToLet i (Lisp.Binder n mty expr) term =
    Let (BN (BareName n)) (desugarType <$> mty) (desugarLispTerm expr) term i
  isReservedNative n =
    Map.member n (reservedNatives @b)
  suspend i e = let
    name = BN (BareName "#ifArg")
    e' = desugarLispTerm e
    in Lam ((name, Just TyUnit) :| []) e' i

desugarDefun :: (DesugarTerm term b i) => Common.Defun term i -> Defun ParsedName b i
desugarDefun (Common.Defun defname [] rt body i) = let
  dfnType = TyFun TyUnit (desugarType rt)
  lamName = BN (BareName defname)
  body' = Lam ((lamName, Just TyUnit) :| []) (desugarTerm body) i
  in Defun defname dfnType body' i
desugarDefun (Common.Defun defname (arg:args) rt body i) = let
  neArgs = arg :| args
  dfnType = foldr TyFun (desugarType rt) (desugarType . Common._argType <$> neArgs)
  lamArgs = (\(Common.Arg n ty) -> (BN (BareName n), Just (desugarType ty))) <$> neArgs
  body' = Lam lamArgs (desugarTerm body) i
  in Defun defname dfnType body' i

desugarDefConst :: (DesugarTerm term b i) => Common.DefConst term i -> DefConst ParsedName b i
desugarDefConst (Common.DefConst n mty e i) = let
  mty' = desugarType <$> mty
  e' = desugarTerm e
  in DefConst n mty' e' i

desugarDefCap :: DesugarTerm expr builtin info => Common.DefCap expr info -> DefCap ParsedName builtin info
desugarDefCap (Common.DefCap dn argList managed term i) = let
  managed' = maybe Unmanaged fromCommonCap managed
  lamArgs = (\(Common.Arg n ty) -> (BN (BareName n), Just (desugarType ty))) <$> argList
  -- term' = Lam lamArgs (desugarTerm term) i
  capType = foldr TyFun TyCap (desugarType . Common._argType <$> argList)
  in case lamArgs of
    [] -> DefCap dn [] (desugarTerm term) managed' capType i
    (arg:args) ->  DefCap dn [] (Lam (arg :| args) (desugarTerm term) i) managed' capType i
  where
  fromCommonCap = \case
    Common.AutoManaged -> AutomanagedCap
    Common.Managed t pn -> case findIndex ((== t) . Common._argName) argList of
      Nothing -> error "invalid managed cap decl"
      Just n -> let
        ty' = desugarType $ Common._argType (argList !! n)
        in ManagedCap n ty' pn


desugarDef :: (DesugarTerm term b i) => Common.Def term i -> Def ParsedName b i
desugarDef = \case
  Common.Dfun d -> Dfun (desugarDefun d)
  Common.DConst d -> DConst (desugarDefConst d)
  Common.DCap d -> DCap (desugarDefCap d)

desugarModule :: (DesugarTerm term b i) => Common.Module term i -> Module ParsedName b i
desugarModule (Common.Module mname gov extdecls defs) = let
  (imports, blessed, implemented) = splitExts extdecls
  defs' = desugarDef <$> NE.toList defs
  mhash = ModuleHash (Hash "placeholder")
  gov' = BN . BareName <$> gov
  in Module mname gov' defs' blessed imports implemented mhash
  where
  splitExts = split ([], Set.empty, [])
  split (accI, accB, accImp) (h:hs) = case h of
    -- todo: implement bless hashes
    Common.ExtBless _ -> split (accI, accB, accImp) hs
    Common.ExtImport i -> split (i:accI, accB, accImp) hs
    Common.ExtImplements mn -> split (accI, accB, mn:accImp) hs
  split (a, b, c) [] = (reverse a, b, reverse c)


desugarType :: Common.Type -> Type a
desugarType = \case
  Common.TyPrim p -> TyPrim p
  Common.TyFun l r ->
    TyFun (desugarType l) (desugarType r)
  Common.TyObject o ->
    let o' = desugarType <$> o
    in TyRow (RowTy o' Nothing)
  Common.TyList t ->
    TyList (desugarType t)
  Common.TyCap -> TyCap

desugarUnary' :: Common.UnaryOp -> RawBuiltin
desugarUnary' = \case
  Common.NegateOp -> RawNegate
  Common.FlipBitsOp -> RawBitwiseFlip

desugarBinary' :: Common.BinaryOp -> RawBuiltin
desugarBinary' = \case
  Common.AddOp -> RawAdd
  Common.SubOp -> RawSub
  Common.MultOp -> RawMultiply
  Common.DivOp -> RawDivide
  Common.GTOp -> RawGT
  Common.GEQOp -> RawGEQ
  Common.LTOp -> RawLT
  Common.LEQOp -> RawLEQ
  Common.EQOp -> RawEq
  Common.NEQOp -> RawNeq
  Common.BitAndOp -> RawBitwiseAnd
  Common.BitOrOp -> RawBitwiseOr
  Common.AndOp -> RawAnd
  Common.OrOp -> RawOr

-----------------------------------------------------------
-- Renaming
-----------------------------------------------------------

termSCC
  :: ModuleName
  -> Term IRName b1 i1
  -> Set Text
termSCC currM = conn
  where
  conn = \case
    Var n _ -> case _irNameKind n of
      IRTopLevel m _ | m == currM ->
        Set.singleton (_irName n)
      _ -> Set.empty
    Lam _ e _ -> conn e
    Let _ _ e1 e2 _ -> Set.union (conn e1) (conn e2)
    App fn apps _ ->
      Set.union (conn fn) (foldMap conn apps)
    Block nel _ -> foldMap conn nel
    Builtin{} -> Set.empty
    DynAccess{} -> Set.empty
    Constant{} -> Set.empty
    ObjectLit o _ -> foldMap conn o
    ListLit v _ -> foldMap conn v
    ObjectOp o _ -> foldMap conn o


defunSCC :: ModuleName -> Defun IRName b i -> Set Text
defunSCC mn = termSCC mn . _dfunTerm

defConstSCC :: ModuleName -> DefConst IRName b i -> Set Text
defConstSCC mn = termSCC mn . _dcTerm

defCapSCC :: ModuleName -> DefCap IRName b i -> Set Text
defCapSCC mn = termSCC mn . _dcapTerm

defSCC :: ModuleName -> Def IRName b i1 -> Set Text
defSCC mn = \case
  Dfun d -> defunSCC mn d
  DConst d -> defConstSCC mn d
  DCap d -> defCapSCC mn d

-- | Look up a qualified name in the pact db
-- if it's there, great! We will load the module into the scope of
-- `Loaded`, as well as include it in the renamer map
-- Todo: Bare namespace lookup first, then
-- current namespace.
-- Namespace definitions are yet to be supported in core
lookupModuleMember
  :: ModuleName
  -> Text
  -> RenamerM cb ci IRName
lookupModuleMember modName name = do
  view rePactDb >>= liftIO . (`_readModule` modName) >>= \case
    Just md -> let
      module_ = _mdModule md
      mhash = Term._mHash module_
      depMap = Map.fromList $ toDepMap mhash <$> Term._mDefs module_
      in case Map.lookup name depMap of
        -- Great! The name exists
        -- This, we must include the module in `Loaded`, as well as propagate its deps and
        -- all loaded members in `loAllLoaded`
        Just irtl -> do
          let memberTerms = Map.fromList (toFqDep mhash <$> Term._mDefs module_)
              allDeps = Map.union memberTerms (_mdDependencies md)
          rsLoaded %= over loModules (Map.insert modName md) . over loAllLoaded (Map.union allDeps)
          rsModuleBinds %= Map.insert modName depMap
          rsDependencies %= Set.insert modName
          pure (IRName name irtl dummyTLUnique)
        -- Module exists, but it has no such member
        -- Todo: check whether the module name includes a namespace
        -- if it does not, we retry the lookup under the current namespace
        Nothing -> fail "boom: module does not have member"
    Nothing -> fail "no such module"
  where
  rawDefName def = Term.defName def
  toDepMap mhash def = (rawDefName def, IRTopLevel modName mhash)
  toFqDep mhash def = let
    fqn = FullyQualifiedName modName (rawDefName def) mhash
    in (fqn, Term.defTerm def)

-- Rename a term (that is part of a module)
-- emitting the list of dependent calls
renameTerm
  :: Term ParsedName b i
  -> RenamerM cb ci (Term IRName b i)
renameTerm (Var n i) = (`Var` i) <$> resolveName n
renameTerm (Lam nsts body i) = do
  let (pns, ts) = NE.unzip nsts
      ns = rawParsedName <$> pns
  nUniques <- traverse (const newUnique') ns
  let m = Map.fromList $ NE.toList $ NE.zip ns ((IRBound,) <$> nUniques)
      ns' = NE.zipWith (`IRName` IRBound) ns nUniques
  term' <- locally reBinds (Map.union m) (renameTerm body)
  pure (Lam (NE.zip ns' ts) term' i)
renameTerm (Let name mt e1 e2 i) = do
  nu <- newUnique'
  let rawName = rawParsedName name
      name' = IRName rawName IRBound nu
  e1' <- renameTerm e1
  e2' <- locally reBinds (Map.insert rawName (IRBound, nu)) (renameTerm e2)
  pure (Let name' mt e1' e2' i)
renameTerm (App fn apps i) = do
  fn' <- renameTerm fn
  apps' <- traverse renameTerm apps
  pure (App fn' apps' i)
renameTerm (Block exprs i) = do
  exprs' <- traverse renameTerm exprs
  pure (Block exprs' i)
renameTerm (Builtin b i) = pure (Builtin b i)
renameTerm DynAccess{} = fail "todo: implement"
renameTerm (Constant l i) =
  pure (Constant l i)
renameTerm (ObjectLit o i) =
  ObjectLit <$> traverse renameTerm o <*> pure i
renameTerm (ListLit v i) = do
  ListLit <$> traverse renameTerm v <*> pure i
renameTerm (ObjectOp o i) = do
  ObjectOp <$> traverse renameTerm o <*> pure i

renameDefun
  :: Defun ParsedName b i
  -> RenamerM cb ci (Defun IRName b i)
renameDefun (Defun n dty term i) = do
  -- Todo: put type variables in scope here, if we want to support polymorphism
  term' <- renameTerm term
  pure (Defun n dty term' i)

renameDefConst
  :: DefConst ParsedName b i
  -> RenamerM cb ci (DefConst IRName b i)
renameDefConst (DefConst n mty term i) = do
  -- Todo: put type variables in scope here, if we want to support polymorphism
  term' <- renameTerm term
  pure (DefConst n mty term' i)

renameDefCap
  :: DefCap ParsedName builtin info
  -> RenamerM cb ci (DefCap IRName builtin info)
renameDefCap (DefCap name args term capType ty i) = do
  term' <- renameTerm term
  capType' <- traverse resolveName capType
  pure (DefCap name args term' capType' ty i)

renameDef
  :: Def ParsedName b i
  -> RenamerM cb ci (Def IRName b i)
renameDef = \case
  Dfun d -> Dfun <$> renameDefun d
  DConst d -> DConst <$> renameDefConst d
  DCap d -> DCap <$> renameDefCap d

resolveName :: ParsedName -> RenamerM b i IRName
resolveName = \case
  BN b -> resolveBare b
  QN q -> resolveQualified q

-- not in immediate binds, so it must be in the module
-- Todo: resolve module ref within this model
-- Todo: hierarchical namespace search
resolveBare :: BareName -> RenamerM cb ci IRName
resolveBare (BareName bn) = views reBinds (Map.lookup bn) >>= \case
  Just (irnk, u) ->
    pure (IRName bn irnk u)
  Nothing -> uses (rsLoaded . loToplevel) (Map.lookup bn) >>= \case
    Just fqn -> pure (IRName bn (IRTopLevel (_fqModule fqn) (_fqHash fqn)) dummyTLUnique)
    Nothing -> fail $ "unbound free variable " <> show bn

resolveBareName' :: Text -> RenamerM b i IRName
resolveBareName' bn = views reBinds (Map.lookup bn) >>= \case
  Just (irnk, u) -> pure (IRName bn irnk u)
  Nothing -> fail $ "Expected identifier " <> T.unpack bn <> " in scope"

resolveQualified :: QualifiedName -> RenamerM b i IRName
resolveQualified (QualifiedName qn qmn) = do
  uses rsModuleBinds (Map.lookup qmn) >>= \case
    Just binds -> case Map.lookup qn binds of
      Just irnk -> pure (IRName qn irnk dummyTLUnique)
      Nothing -> fail "bound module has no such member"
    Nothing -> lookupModuleMember qmn qn

-- | Todo: support imports
renameModule
  :: Module ParsedName b i
  -> RenamerM cb ci (Module IRName b i)
renameModule (Module mname mgov defs blessed imp implements mhash) = do
  let rawDefNames = defName <$> defs
      defMap = Map.fromList $ (, (IRTopLevel mname mhash, dummyTLUnique)) <$> rawDefNames
      fqns = Map.fromList $ (\n -> (n, FullyQualifiedName mname n mhash)) <$> rawDefNames
  -- `maybe all of this next section should be in a block laid out by the
  -- `locally reBinds`
  rsModuleBinds %= Map.insert mname (fst <$> defMap)
  rsLoaded . loToplevel %= Map.union fqns
  defs' <- locally reBinds (Map.union defMap) $ traverse renameDef defs
  let scc = mkScc <$> defs'
  defs'' <- forM (stronglyConnComp scc) \case
    AcyclicSCC d -> pure d
    CyclicSCC d -> fail $ "Functions: " <> show (defName  <$> d) <> " form a cycle"
  mgov' <- locally reBinds (Map.union defMap) $ traverse (resolveBareName' . rawParsedName) mgov
  pure (Module mname mgov' defs'' blessed imp implements mhash)
  where
  mkScc def = (def, defName def, Set.toList (defSCC mname def))

runRenamerT
  :: RenamerState b i
  -> RenamerEnv b i
  -> RenamerM b i a
  -> IO (a, RenamerState b i)
runRenamerT st env (RenamerT act) = runReaderT (runStateT act st) env

reStateFromLoaded :: Loaded b i -> RenamerState b i
reStateFromLoaded loaded = RenamerState mbinds loaded Set.empty
  where
  mbind md = let
    m = _mdModule md
    depNames = Term.defName <$> Term._mDefs m
    in Map.fromList $ (,IRTopLevel (Term._mName m) (Term._mHash m)) <$> depNames
  mbinds = fmap mbind (_loModules loaded)

loadedBinds :: Loaded b i -> Map Text (IRNameKind, Unique)
loadedBinds loaded =
  let f fqn  = (IRTopLevel (_fqModule fqn) (_fqHash fqn), dummyTLUnique)
  in f <$> _loToplevel loaded

runDesugar'
  :: PactDb b i
  -> Loaded b i
  -> Supply
  -> RenamerM b i a
  -> IO (DesugarOutput b i a)
runDesugar' pdb loaded supply act = do
  ref <- newIORef supply
  let reState = reStateFromLoaded loaded
      rTLBinds = loadedBinds loaded
      rEnv = RenamerEnv rTLBinds ref pdb
  (renamed, RenamerState _ loaded' deps) <- runRenamerT reState rEnv act
  lastSupply <- readIORef ref
  pure (DesugarOutput renamed lastSupply loaded' deps)

runDesugarTerm'
  :: (DesugarTerm term b' i)
  => PactDb b i
  -> Loaded b i
  -> Supply
  -> term
  -> IO (DesugarOutput b i (Term IRName b' i))
runDesugarTerm' pdb loaded supply e = let
  desugared = desugarTerm e
  in runDesugar' pdb loaded supply (renameTerm desugared)

runDesugarTerm
  :: (DesugarTerm term b' i)
  => PactDb b i
  -> Loaded b i
  -> term
  -> IO (DesugarOutput b i (Term IRName b' i))
runDesugarTerm pdb loaded = runDesugarTerm' pdb loaded 0

runDesugarModule'
  :: (DesugarTerm term b' i)
  => PactDb b i
  -> Loaded b i
  -> Supply
  -> Common.Module term i
  -> IO (DesugarOutput b i (Module IRName b' i))
runDesugarModule' pdb loaded supply m  = let
  desugared = desugarModule m
  in runDesugar' pdb loaded supply (renameModule desugared)

-- runDesugarModule
--   :: (DesugarTerm term b' i)
--   => Loaded b i
--   -> Common.Module term i
--   -> IO (DesugarOutput b i (Module IRName TypeVar b' i))
-- runDesugarModule loaded = runDesugarModule' loaded 0

runDesugarTopLevel'
  :: (DesugarTerm term b' i)
  => PactDb b i
  -> Loaded b i
  -> Supply
  -> Common.TopLevel term i
  -> IO (DesugarOutput b i (TopLevel IRName b' i))
runDesugarTopLevel' pdb loaded supply = \case
  Common.TLModule m -> over dsOut TLModule <$> runDesugarModule' pdb loaded supply m
  Common.TLTerm e -> over dsOut TLTerm <$> runDesugarTerm' pdb loaded supply e

runDesugarTopLevel
  :: (DesugarTerm term b' i)
  => PactDb b i
  -> Loaded b i
  -> Common.TopLevel term i
  -> IO (DesugarOutput b i (TopLevel IRName b' i))
runDesugarTopLevel pdb loaded = runDesugarTopLevel' pdb loaded 0

runDesugarTermNew
  :: (DesugarBuiltin b')
  => PactDb b i
  -> Loaded b i
  -> New.Expr ParsedName i
  -> IO (DesugarOutput b i (Term IRName b' i))
runDesugarTermNew = runDesugarTerm

runDesugarTopLevelNew
  :: (DesugarBuiltin b')
  => PactDb b i
  -> Loaded b i
  -> Common.TopLevel (New.Expr ParsedName i) i
  -> IO (DesugarOutput b i (TopLevel IRName b' i))
runDesugarTopLevelNew = runDesugarTopLevel

runDesugarTermLisp
  :: (DesugarBuiltin b')
  => PactDb b i
  -> Loaded b i
  -> Lisp.Expr ParsedName i
  -> IO (DesugarOutput b i (Term IRName b' i))
runDesugarTermLisp = runDesugarTerm

runDesugarTopLevelLisp
  :: (DesugarBuiltin b')
  => PactDb b i
  -> Loaded b i
  -> Common.TopLevel (Lisp.Expr ParsedName i) i
  -> IO (DesugarOutput b i (TopLevel IRName b' i))
runDesugarTopLevelLisp = runDesugarTopLevel
