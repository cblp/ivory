{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}

--
-- QuasiQuoter for Ivory statements.
--
-- Copyright (C) 2014, Galois, Inc.
-- All rights reserved.
--

module Ivory.Language.Syntax.Concrete.QQ.StmtQQ
 ( fromProgram
 , mkDerefStmts
 ) where

import           Prelude hiding (exp, init)

import Ivory.Language.Syntax.Concrete.QQ.ExprQQ
import Ivory.Language.Syntax.Concrete.QQ.Types
import Ivory.Language.Syntax.Concrete.QQ.Common

import           Language.Haskell.TH       hiding (Stmt, Exp, Type)
import qualified Language.Haskell.TH as T

import qualified Ivory.Language.Init   as I
import qualified Ivory.Language.Ref    as I
import qualified Ivory.Language.Proc   as I
import qualified Ivory.Language.Assert as I
import qualified Ivory.Language.IBool  as I
import qualified Ivory.Language.Array  as I
import qualified Ivory.Language.Struct as I
import qualified Ivory.Language.Loop   as I
import qualified Ivory.Language.Monad  as I

import           Control.Monad (forM_)

import Ivory.Language.Syntax.Concrete.ParseAST

--------------------------------------------------------------------------------

-- We use a state monad over the Q monad to keep track of expressions in the
-- parsed language that we'll turn into statements in Ivory.
type TStmtM a = QStM T.Stmt a

--------------------------------------------------------------------------------

fromProgram :: [Stmt] -> Q T.Exp
fromProgram program =
  if null program then [| return () |]
    else  return . DoE =<< (runToSt $ forM_ program fromStmt)

fromBlock :: [Stmt] -> TStmtM T.Exp
fromBlock = liftQ . fromProgram

fromStmt :: Stmt -> TStmtM ()
fromStmt stmt = case stmt of
  IfTE cond blk0 blk1
    -> do
    cd <- fromExp cond
    b0 <- fromBlock blk0
    b1 <- fromBlock blk1
    insert $ NoBindS (AppE (AppE (AppE (VarE 'I.ifte_) cd) b0) b1)
  Assert exp
    -> do
    e <- fromExp exp
    insert $ NoBindS (AppE (VarE 'I.assert) e)
  Assume exp
    -> do
    e <- fromExp exp
    insert $ NoBindS (AppE (VarE 'I.assume) e)
  Return exp
    -> do
    e <- fromExp exp
    insert $ NoBindS (AppE (VarE 'I.ret) e)
  ReturnVoid
    -> insert $ NoBindS (VarE 'I.retVoid)
  Store ptr exp
    -> do
      e <- fromExp exp
      let storeIt p = insert $ NoBindS (AppE (AppE (VarE 'I.store) p) e)
      case ptr of
        RefVar ref -- ref
          -> storeIt (VarE (mkName ref))
        ArrIx ref ixExp -- (arr ! ix)
          -> do ix <- fromExp ixExp
                storeIt $ InfixE (Just (mkVar ref)) (VarE '(I.!)) (Just ix)
        StructField struct field -- (struct . field)
          -> storeIt $ InfixE (Just (mkVar struct))
                              (VarE '(I.~>))
                              (Just (mkVar field))
  Assign var exp
    -> do
    e <- fromExp exp
    let v = mkName var
    insert $ BindS (VarP v) (AppE (VarE 'I.assign) e)
  Call mres sym exps
    -> do
    es <- mapM fromExp exps
    let call f = AppE (VarE f) (mkVar sym)
    insert $ case mres of
      Nothing  -> NoBindS (callit (call 'I.call_) es)
      Just res -> let r = mkName res in
                  BindS (VarP r) (callit (call 'I.call) es)
  RefCopy refDest refSrc
    -> do
    eDest <- fromExp refDest
    eSrc  <- fromExp refSrc
    insert $ NoBindS (AppE (AppE (VarE 'I.refCopy) eDest) eSrc)
  Forever blk
    -> do
    b <- fromBlock blk
    insert $ NoBindS (AppE (VarE 'I.forever) b)
--  Break -> insert $ NoBindS (VarE 'I.break)
  AllocRef alloc
    -> fromAlloc alloc
  Loop ixVar blk
    -> do
    b <- fromBlock blk
    insert $ NoBindS (AppE (VarE 'I.arrayMap) (LamE [VarP (mkName ixVar)] b))
  -- Either a single variable or a function call.
  IvoryMacroStmt m v exps
    -> do es <- mapM fromExp exps
          let c = callit (mkVar v) es
          insert $ case m of
                     NoBind  -> NoBindS c
                     Bind bv -> BindS (VarP $ mkName bv) c

--------------------------------------------------------------------------------
-- Initializers

fromAlloc :: AllocRef -> TStmtM ()
fromAlloc alloc = case alloc of
  AllocBase ref exp
    -> do e <- fromExp exp
          let p = mkName ref
          insert $ BindS (VarP p)
                         (AppE (VarE 'I.local) (AppE (VarE 'I.ival) e))
  AllocArr arr exps
    -> do es <- mapM fromExp exps
          let mkIval = AppE (VarE 'I.ival)
          let init = ListE (map mkIval es)
          let p = mkName arr
          insert $ BindS (VarP p)
                         (AppE (VarE 'I.local) (AppE (VarE 'I.iarray) init))

-----------------------------------------
-- Insert dereference statements

-- Collect up dereference expressions, which turn into Ivory statements.  We
-- only need one dereference statement for each unique dereferenced equation.
fromExp :: Exp -> TStmtM T.Exp
fromExp exp = do
  env <- mkDerefStmts exp
  return (toExp env exp)

mkDerefStmts :: Exp -> TStmtM DerefVarEnv
mkDerefStmts exp = do
  envs <- mapM insertDerefStmt (collectRefExps exp)
  return (concat envs)

-- For each unique expression that requires a dereference, insert a dereference
-- statement.
insertDerefStmt :: DerefExp -> TStmtM DerefVarEnv
insertDerefStmt dv = case dv of
  RefExp var    -> do
    nm <- liftQ (freshDeref var)
    insertDeref nm (mkVar var)
    return [(dv, nm)]
  RefArrIxExp ref ixExp -> do
    env <- mkDerefStmts ixExp
    nm <- liftQ (freshDeref ref)
    insertDeref nm (toArrIxExp env ref ixExp)
    return ((dv, nm) : env)
  RefFieldExp ref fieldNm -> do
    nm <- liftQ (freshDeref ref)
    insertDeref nm (toFieldExp ref fieldNm)
    return [(dv, nm)]
  where
  -- We want to generate a fresh name that won't capture other user-defined
  -- names, since we're inserting these variables.
  freshDeref = newName . ("deref_" ++)
  insertDeref nm exp = insert $ BindS (VarP nm) (AppE (VarE 'I.deref) exp)

--------------------------------------------------------------------------------