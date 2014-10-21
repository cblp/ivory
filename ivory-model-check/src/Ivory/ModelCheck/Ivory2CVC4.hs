{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# OPTIONS_GHC -fno-warn-unused-binds   #-}
{-# OPTIONS_GHC -fno-warn-unused-matches #-}
{-# LANGUAGE TupleSections #-}
module Ivory.ModelCheck.Ivory2CVC4
--  ( modelCheckMod )
 where

import           Control.Applicative
import           Control.Monad
import           Data.Maybe
import qualified Ivory.Language.Array   as I
import qualified Ivory.Language.Cast    as I
import qualified Ivory.Language.Syntax  as I
import           Ivory.Opts.ConstFold   (constFold)
import           Ivory.Opts.Overflow    (overflowFold)
import           Prelude                hiding (exp)

import           Ivory.ModelCheck.CVC4
import           Ivory.ModelCheck.Monad

-- XXX testing
-- import           Debug.Trace

--------------------------------------------------------------------------------

modelCheckMod :: I.Module -> ModelCheck ()
modelCheckMod m = do
  mapM_ toStruct (getVisible $ I.modStructs m)
  mapM_ addExtern (I.modExterns m)
  mapM_ addImport (I.modImports m)
  mapM_ addProc (getVisible $ I.modProcs m)
  mapM_ toArea (getVisible $ I.modAreas m)
  mapM_ (modelCheckProc . overflowFold . constFold) (getVisible $ I.modProcs m)
  where
  getVisible ps = I.public ps ++ I.private ps
  addExtern e = addProc $ I.Proc { I.procSym = I.externSym e
                                 , I.procRetTy = I.externRetType e
                                 , I.procArgs = zipWith I.Typed
                                                (I.externArgs e)
                                                (repeat $ I.VarName "dummy")
                                 , I.procBody = []
                                 , I.procRequires = []
                                 , I.procEnsures = []
                                 }
  addImport e = addProc $ I.Proc { I.procSym = I.importSym e
                                 , I.procRetTy = err "addImport" "tried to use return type"
                                 , I.procArgs = []
                                 , I.procBody = []
                                 , I.procRequires = []
                                 , I.procEnsures = []
                                 }

--------------------------------------------------------------------------------

toArea :: I.Area -> ModelCheck ()
toArea I.Area { I.areaSym  = sym
              , I.areaType = ty
              }
  = void $ addEnvVar ty sym

--------------------------------------------------------------------------------

modelCheckProc :: I.Proc -> ModelCheck ()
modelCheckProc I.Proc { I.procSym      = sym
                      , I.procRetTy    = ret
                      , I.procArgs     = args
                      , I.procBody     = body
                      , I.procRequires = requires
                      , I.procEnsures  = ensures
                      }
  = do
  mapM_ toParam args
  mapM_ toRequire requires
  unless (ret == I.TyVoid) $
    void $ addEnvVar ret "retval"
  ens <- mapM toEnsure ensures
  mapM_ (toBody ens) body

--------------------------------------------------------------------------------

toParam :: I.Typed I.Var -> ModelCheck ()
toParam (I.Typed t val) = do
  v <- addEnvVar t (toVar val)
  assertBoundedVar t (var v)

--------------------------------------------------------------------------------

toRequire :: I.Require -> ModelCheck ()
toRequire (I.Require cond) = do
  e <- toAssertion id cond
  addInvariant e

--------------------------------------------------------------------------------

toEnsure :: I.Ensure -> ModelCheck Expr
toEnsure (I.Ensure cond) = toAssertion id cond

--------------------------------------------------------------------------------

toAssertion :: (I.Expr -> I.Expr) -> I.Cond -> ModelCheck Expr
toAssertion trans cond = case cond of
    I.CondBool exp -> toExpr I.TyBool (trans exp)
    I.CondDeref t exp var c -> do
      e <- toExpr t exp
      toAssertion (subst [(var, exp)] . trans) c

--------------------------------------------------------------------------------

-- | Symbolically execute statements, carrying the return requirements forward
-- to each location that there is a return statement.
toBody :: [Expr] -> I.Stmt -> ModelCheck ()
toBody ens stmt =
  case stmt of
    I.IfTE exp blk0 blk1   -> toIfTE ens exp blk0 blk1
    I.Assume exp           -> addInvariant =<< toExpr I.TyBool exp
    I.Assert exp           -> addQuery =<< toExpr I.TyBool exp
    I.CompilerAssert exp   -> addQuery =<< toExpr I.TyBool exp
    I.Return (I.Typed t e) -> toReturn ens t e
    I.ReturnVoid           -> return ()
    I.Deref t v ref        -> toDeref t v ref
    I.Store t ptr exp      -> toStore t ptr exp
    I.RefCopy t ptr exp    -> toStore t ptr exp -- XXX is this correct?
    I.Assign t v exp       -> toAssign t v exp
    I.Call t retV nm args  -> toCall t retV nm args
    I.Local t v inits      -> toLocal t v inits

    I.AllocRef t ref name  -> toAlloc t ref name

    I.Loop v exp inc blk   -> toLoop ens v exp inc blk
    I.Comment _            -> return ()
    I.Break                -> err "toBody" (show stmt)
    I.Forever _            -> err "toBody" (show stmt)

toReturn :: [Expr] -> I.Type -> I.Expr -> ModelCheck ()
toReturn ens t exp = do
  void $ toExpr t exp
  queryEnsures ens t exp

toDeref :: I.Type -> I.Var -> I.Expr -> ModelCheck ()
toDeref t v ref = do
  v' <- addEnvVar t (toVar v)
  e  <- toExpr t ref
  addInvariant (var v' .== e)

toAlloc :: I.Type -> I.Var -> I.Name -> ModelCheck ()
toAlloc t ref name = do
  v' <- addEnvVar t (toVar ref)
  n' <- lookupVar (toName name)
  addInvariant (var v' .== var n')

toStore :: I.Type -> I.Expr -> I.Expr -> ModelCheck ()
toStore t e@(I.ExpIndex{}) exp = toSelectStore t e exp
toStore t e@(I.ExpLabel{}) exp = toSelectStore t e exp
toStore t ptr exp = do
  v' <- updateEnvRef t ptr
  e  <- toExpr t exp
  addInvariant (var v' .== e)

toSelectStore :: I.Type -> I.Expr -> I.Expr -> ModelCheck ()
toSelectStore t f exp = do
  f'   <- toExpr t f
  v    <- toStoreRef t f
  e    <- toExpr t exp
  addInvariant (var v .== store f' e)

toLocal :: I.Type -> I.Var -> I.Init -> ModelCheck ()
toLocal t v inits = do
  v' <- addEnvVar t (toVar v)
  is <- toInit t inits
  addInvariant (var v' .== is)

toInit :: I.Type -> I.Init -> ModelCheck Expr
toInit ty init =
  case init of
    I.InitZero       ->
      case ty of
       I.TyArr _ _ -> fmap var $ incReservedVar =<< toType ty
       I.TyStruct _-> fmap var $ incReservedVar =<< toType ty
       _           -> return $ intLit 0
    I.InitExpr t exp -> toExpr t exp
    I.InitArray is   -> do
      let (I.TyArr k t) = ty
      tv <- fmap var $ incReservedVar =<< toType ty
      forM_ (zip [0..] is) $ \ (ix,i) -> do
        e <- toInit (err "toInit" "nested array") i
        addInvariant (index (intLit ix) tv .== e)
      return tv
    I.InitStruct fs  -> do
      tv <- fmap var $ incReservedVar =<< toType ty
      forM_ fs $ \ (f, i) -> do
        e <- toInit (err "toInit" "nested struct") i
        addInvariant (field (var f) tv .== e)
      return tv

toAssign :: I.Type -> I.Var -> I.Expr -> ModelCheck ()
toAssign t v exp = do
  e  <- toExpr t exp
  v' <- addEnvVar t (toVar v)
  addInvariant $ (var v' .== e)

toCall :: I.Type -> Maybe I.Var -> I.Name -> [I.Typed I.Expr] -> ModelCheck ()
toCall t retV nm args = do
  pc <- lookupProc $ toName nm
  let su = [ (v, e) | (I.Typed _ v, I.Typed _ e) <- zip (I.procArgs pc) args]
  checkRequires su $ I.procRequires pc

  case retV of
    Nothing -> return ()
    Just v  -> do
      r <- addEnvVar t (toVar v)
      assumeEnsures ((I.retval, I.ExpVar $ I.VarName r) : su)
                    (I.procEnsures pc)
      return ()
  where
  checkRequires su reqs = forM_ reqs $ \ (I.Require c) -> do
    addQuery =<< toAssertion (subst su) c
    
  assumeEnsures su ens = forM_ ens $ \ (I.Ensure c) -> do
    addInvariant =<< toAssertion (subst su) c


-- XXX Abstraction (to implement): If there is load/stores in the block, the we
-- don't care how many times it iterates.  It's pure.
toLoop :: [Expr] -> I.Var -> I.Expr -> I.LoopIncr -> [I.Stmt] -> ModelCheck ()
toLoop ens v start end blk =
  mapM_ go ixs
  where
  go :: Integer -> ModelCheck ()
  go ix = do
    v' <- addEnvVar t (toVar v)
    addInvariant (var v' .== intLit ix)
    mapM_ (toBody ens) blk

  t = I.ixRep

  loopData = loopIterations start end

  ixs | loopOp loopData == Incr
      = takeWhile (<= endVal loopData) $
          iterate (+ 1) (startVal loopData)
      | otherwise -- loopOp loopData == Decr
      = takeWhile (>= endVal loopData) $
          iterate (flip (-) 1) (startVal loopData)

toIfTE :: [Expr] -> I.Expr -> [I.Stmt] -> [I.Stmt] -> ModelCheck ()
toIfTE ens cond blk0 blk1 = do
  st  <- getState
  b   <- toExpr I.TyBool cond
  runBranch st b blk0
  st' <- joinState st
  runBranch st (not' b) blk1
  void (joinState st')
  where
  runBranch :: SymExecSt -> Expr -> [I.Stmt] -> ModelCheck ()
  runBranch st b blk = do
    resetSt st                   -- Empty state except environment
    mapM_ (toBody ens) blk       -- Body under the invariant
    branchSt b                   -- Make conditions under hypothesis b

--------------------------------------------------------------------------------

toExpr :: I.Type -> I.Expr -> ModelCheck Expr
toExpr t exp = case exp of
  I.ExpSym s                 -> return (var s)
  I.ExpVar v                 -> lookupVar (toVar v) >>= return . var
  I.ExpLit lit               -> 
    case lit of
      I.LitInteger i -> return $ intLit i
      I.LitFloat  r  -> return $ realLit $ realToFrac r
      I.LitDouble r  -> return $ realLit r
      I.LitBool b    -> return $ if b then T else F
      I.LitChar _    -> fmap var $ incReservedVar =<< toType t
      I.LitNull      -> fmap var $ incReservedVar =<< toType t
      I.LitString _  -> fmap var $ incReservedVar =<< toType t
  I.ExpLabel t' e f          -> do e' <- toExpr t' e
                                   return $ field (var f) e'
  I.ExpIndex ta a ti i       -> do a' <- toExpr ta a
                                   i' <- toExpr ti i
                                   return $ index i' a'
  I.ExpToIx e i              -> toExpr t e
  I.ExpSafeCast t' e         -> do e' <- toExpr t' e
                                   assertBoundedVar t e'
                                   return e'
  I.ExpOp op args            -> toExprOp t op args
  I.ExpAddrOfGlobal s        -> lookupVar s >>= return . var
  I.ExpMaxMin True           -> return $ intLit $ fromJust $ I.toMaxSize t
  I.ExpMaxMin False          -> return $ intLit $ fromJust $ I.toMinSize t

--------------------------------------------------------------------------------

toExprOp :: I.Type -> I.ExpOp -> [I.Expr] -> ModelCheck Expr
toExprOp t op args = case op of
  I.ExpEq t'      -> go t' (mkEq t')
  I.ExpNeq t'     -> toExpr t (I.ExpOp I.ExpNot [I.ExpOp (I.ExpEq t') args])
  I.ExpCond       -> toExpCond t arg0 arg1 arg2
  I.ExpLt orEq t' ->
    case orEq of
      True  -> go t' (.<=)
      False -> go t' (.<)
  I.ExpGt orEq t' ->
    case orEq of
      True  -> go t' (.>=)
      False -> go t' (.>)
  I.ExpNot        -> toExpr I.TyBool arg0 >>= return . not'
  I.ExpAnd        -> go t (.&&)
  I.ExpOr         -> go t (.||)
  I.ExpMod        -> toMod t arg0 arg1
  I.ExpAdd        -> go t (.+)
  I.ExpSub        -> go t (.-)
  I.ExpMul        -> toMul t arg0 arg1
  I.ExpDiv        -> toDiv t arg0 arg1
  I.ExpNegate     ->
    let neg = I.ExpOp I.ExpSub [litOp t 0, arg0] in
    toExpr t neg
  I.ExpAbs        -> do
    v <- fmap var $ incReservedVar =<< toType t
    addInvariant (v .>= intLit 0)
    return v
  _               -> fmap var $ incReservedVar =<< toType t
  where
  arg0 = args !! 0
  arg1 = args !! 1
  arg2 = args !! 2

  mkEq I.TyBool = (.<=>)
  mkEq _        = (.==)

  go t' op = do
    e0 <- toExpr t' arg0
    e1 <- toExpr t' arg1
    return (e0 `op` e1)

toExpCond :: I.Type -> I.Expr -> I.Expr -> I.Expr -> ModelCheck Expr
toExpCond t b x y = do
  v  <- incReservedVar =<< toType t
  b' <- toExpr I.TyBool b
  x' <- toExpr t x
  y' <- toExpr t y
  let v' = var v
  addInvariant ((b' .=> (v' .== x')) .&& (not' b' .=> (v' .== y')))
  return v'

-- Abstraction: a % b (C semantics) implies
--
-- (   ((a => 0) && (a % b => 0) && (a % b < b) && (a % b <= a))
--  || ((a < 0)  && (a % b <= 0) && (a % b > b) && (a % b => a)))
--
-- make a fresh variable v == a % b
-- and assert the above for v then returning it.
toMod :: I.Type -> I.Expr -> I.Expr -> ModelCheck Expr
toMod t e0 e1 = do
  v <- incReservedVar =<< toType t
  a <- toExpr t e0
  b <- toExpr t e1
  let v' = var v
  addInvariant (call modAbs [v', a, b])
  return v'

toMul :: I.Type -> I.Expr -> I.Expr -> ModelCheck Expr
toMul t e0 e1 = do
  v <- incReservedVar =<< toType t
  a <- toExpr t e0
  b <- toExpr t e1
  let v' = var v
  addInvariant (call mulAbs [v', a, b])
  return v'

toDiv :: I.Type -> I.Expr -> I.Expr -> ModelCheck Expr
toDiv t e0 e1 = do
  v <- incReservedVar =<< toType t
  a <- toExpr t e0
  b <- toExpr t e1
  let v' = var v
  addInvariant (call divAbs [v', a, b])
  return v'

--------------------------------------------------------------------------------
-- Helpers

toName :: I.Name -> Var
toName name =
  case name of
    I.NameSym s -> s
    I.NameVar v -> toVar v

toVar :: I.Var -> Var
toVar v =
  case v of
    I.VarName n     -> n
    I.VarInternal n -> n
    I.VarLitName n  -> n

baseType :: I.Type -> Bool
baseType t = case t of
  I.TyBool     -> True
  (I.TyWord _) -> True
  (I.TyInt  _) -> True
  I.TyFloat    -> True
  I.TyDouble   -> True
  _            -> False

-- Abstraction: collapse references.
toType :: I.Type -> ModelCheck Type
toType t = case t of
  I.TyVoid         -> return Void
  (I.TyWord _)     -> return Integer
  (I.TyInt  _)     -> return Integer
  (I.TyIndex n)    -> return Integer
  I.TyBool         -> return Bool
  I.TyChar         -> return Char
  I.TyFloat        -> return Real
  I.TyDouble       -> return Real
  I.TyProc t' ts   -> err "toType" "<< proc >>"
  I.TyRef t'       -> toType t'
  I.TyConstRef t'  -> toType t'
  I.TyPtr t'       -> toType t'
  I.TyArr i t'     -> do t'' <- toType t'
                         return (Array t'')
  I.TyCArray t'    -> do t'' <- toType t'
                         return (Array t'')
  -- I.TyCArray t'    -> err "toType" "<< carray >>"
  I.TyOpaque       -> return Opaque
  I.TyStruct name  -> return $ Struct name

updateEnvRef :: I.Type -> I.Expr -> ModelCheck Var
updateEnvRef t ref =
  case ref of
    I.ExpVar v
      -> addEnvVar t (toVar v)
    I.ExpAddrOfGlobal v
      -> addEnvVar t v

    _ -> err "updateEnvRef" (show ref)


toStoreRef :: I.Type -> I.Expr -> ModelCheck Var
toStoreRef t ref =
  case ref of
    I.ExpIndex t' e _ _
      -> toStoreRef t' e
    I.ExpLabel t' e _
      -> toStoreRef t' e
    I.ExpVar v
      -> addEnvVar t (toVar v)
    I.ExpAddrOfGlobal v
      -> addEnvVar t v

    _ -> err "toStoreRef" (show ref)


data LoopOp = Incr | Decr deriving (Show, Read, Eq)
data Loop = Loop
  { startVal :: Integer
  , endVal   :: Integer
  , loopOp   :: LoopOp
  } deriving (Show, Read, Eq)

-- Compute the number of iterations in a loop.  Assume the constant folder has
-- run.
loopIterations :: I.Expr -> I.LoopIncr -> Loop
loopIterations start end = Loop (getLit start) (snd fromIncr) (fst fromIncr)
  where
  getLit e = case e of
    I.ExpLit l   -> case l of
      I.LitInteger i -> i
      _              -> err "loopIterations.ExpLit" (show e)

    -- Abstract unknown loop length to max allowed by Ix bound
    -- FIXME: this can't possibly scale well..
    I.ExpOp I.ExpMod [_, I.ExpLit l] -> case l of
      I.LitInteger i -> i
      _              -> err "loopIterations.ExpLit" (show e)

    _            -> err "loopIterations" (show e)

  fromIncr = case end of
               I.IncrTo e -> (Incr, getLit e)
               I.DecrTo e -> (Decr, getLit e)

--------------------------------------------------------------------------------
-- Language construction helpers

binOp :: I.ExpOp -> I.Expr -> I.Expr -> I.Expr
binOp op e0 e1 = I.ExpOp op [e0, e1]

-- orOp, andOp :: I.Expr -> I.Expr -> I.Expr
-- orOp  = binOp I.ExpOr
-- andOp = binOp I.ExpAnd

-- leOp, leqOp, geOp, geqOp :: I.Type -> I.Expr -> I.Expr -> I.Expr
-- leOp  t = binOp (I.ExpLt False t)
-- leqOp t = binOp (I.ExpLt True  t)
-- geOp  t = binOp (I.ExpGt False t)
-- geqOp t = binOp (I.ExpGt True  t)

-- negOp :: I.Expr -> I.Expr
-- negOp e = I.ExpOp I.ExpNot [e]

-- addOp :: I.Expr -> I.Expr -> I.Expr
-- addOp e0 e1 = binOp I.ExpAdd e0 e1

-- subOp :: I.Expr -> I.Expr -> I.Expr
-- subOp e0 e1 = binOp I.ExpSub e0 e1

-- incrOp :: I.Type -> I.Expr -> I.Expr
-- incrOp t e = addOp e (litOp t 1)

-- decrOp :: I.Type -> I.Expr -> I.Expr
-- decrOp t e = subOp e (litOp t 1)

litOp :: I.Type -> Integer -> I.Expr
litOp t n = I.ExpLit e
  where
  e = case t of
        I.TyWord _ -> I.LitInteger n
        I.TyInt  _ -> I.LitInteger n
        I.TyFloat  -> I.LitFloat   (fromIntegral n)
        I.TyDouble -> I.LitDouble  (fromIntegral n)
        _          -> err "litOp" (show t)

varOp :: Var -> I.Expr
varOp = I.ExpVar . I.VarName

--------------------------------------------------------------------------------

addEnvVar :: I.Type -> Var -> ModelCheck Var
addEnvVar t v = do
  t' <- toType t
  declUpdateEnv t' v

-- Call the appropriate cvc4lib functions.
assertBoundedVar :: I.Type -> Expr -> ModelCheck ()
assertBoundedVar t e = getBounds t
  where
  getBounds t' = case t' of
    I.TyWord w -> case w of
      I.Word8  -> c word8
      I.Word16 -> c word16
      I.Word32 -> c word32
      I.Word64 -> c word64

    I.TyInt i -> case i of
      I.Int8  -> c int8
      I.Int16 -> c int16
      I.Int32 -> c int32
      I.Int64 -> c int64

    I.TyIndex n -> addInvariant $ (intLit 0 .<= e)
                              .&& (e .<= (intLit n .- intLit 1))

    _         -> return ()

  c f = addInvariant (call f [e])

subst :: [(I.Var, I.Expr)] -> I.Expr -> I.Expr
subst su = loop
  where
  loop e = case e of
    I.ExpSym{}             -> e
    I.ExpVar v             -> case lookup v su of
                               Nothing -> e
                               Just e' -> e'
    I.ExpLit{}             -> e
    I.ExpOp op args        -> I.ExpOp op (map loop args)
    I.ExpLabel t e0 s      -> I.ExpLabel t (loop e0) s
    I.ExpIndex t e0 t1 e1  -> I.ExpIndex t (loop e0) t1 (loop e1)
    I.ExpSafeCast t e0     -> I.ExpSafeCast t (loop e0)
    I.ExpToIx e0 maxSz     -> I.ExpToIx (loop e0) maxSz
    I.ExpAddrOfGlobal{}    -> e
    I.ExpMaxMin{}          -> e

queryEnsures :: [Expr] -> I.Type -> I.Expr -> ModelCheck ()
queryEnsures ens t retE = do
  exp <- toExpr t retE
  mapM_ (addQuery . substExpr [("retval", exp)]) ens


toStruct :: I.Struct -> ModelCheck ()
toStruct (I.Abstract name _) = addType name []
toStruct (I.Struct name fields) = do
  fs <- forM fields $ \ (I.Typed t f) -> (f,) <$> toType t
  addType name fs

err :: String -> String -> a
err f msg = error $ "in ivory-model-check. Unexpected: " ++ msg
         ++ " in function " ++ f

--------------------------------------------------------------------------------

