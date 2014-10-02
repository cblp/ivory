{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE FlexibleInstances #-}
module Main where

import Ivory.Language hiding (Struct, assert, true, false, proc, (.&&))
import qualified Ivory.Language as L
import Ivory.ModelCheck

import Text.Printf

import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [ shouldPass, shouldFail ]

shouldPass :: TestTree
shouldPass = testGroup "shouldPass"
             [ mkSuccess "foo2" m2
             , mkSuccess "foo3" m3
             , mkSuccess "foo4" m4
             , mkSuccess "foo5" m5
             , mkSuccess "foo6" m6
             , mkSuccess "foo7" m7
             , mkSuccess "foo8" m8
             , mkSuccess "foo9" m9
             , mkSuccess "foo10" m10
             , mkSuccess "foo11" m11
             , mkSuccess "foo12" m12
             , mkSuccess "foo13" m13
             , mkSuccess "foo15" m15
             ]

shouldFail :: TestTree
shouldFail = testGroup "shouldFail"
             [ mkFailure "foo1" m1
             , mkFailure "foo14" m14
             ]

testArgs = initArgs { printQuery = False, printEnv = False }

mkSuccess nm m = testCase nm $ do
  (r, f) <- modelCheck testArgs m
  let msg = printf "Expected: Safe\nActual: %s\n(check %s for details)"
            (showResult r) f
  assertBool msg (isSafe r)

mkFailure nm m = testCase nm $ do
  (r, f) <- modelCheck testArgs m
  let msg = printf "Expected: Unsafe\nActual: %s\n(check %s for details)"
            (showResult r) f
  assertBool msg (isUnsafe r)

--------------------------------------------------------------------------------
-- test modules

foo1 :: Def ('[Uint8, Uint8] :-> ())
foo1 = L.proc "foo1" $ \y x -> body $ do
  ifte_ (y <? 3)
    (do ifte_ (y ==? 3)
              (L.assert $ y ==? 0)
              retVoid)
    (do z <- assign x
        -- this *should* fail
        L.assert (z >=? 3))
  retVoid

m1 :: Module
m1 = package "foo1" (incl foo1)

-----------------------

foo2 :: Def ('[] :-> ())
foo2 = L.proc "foo2" $ body $ do
  x <- local (ival (0 :: Uint8))
  store x 3
  y <- assign x
  z <- deref y
  L.assert (z ==? 3)
  retVoid

m2 :: Module
m2 = package "foo2" (incl foo2)

-----------------------

foo3 :: Def ('[] :-> ())
foo3 = L.proc "foo3" $ body $ do
  x <- local (ival (1 :: Sint32))
  -- since ivory loops are bounded, we can just unroll the whole thing!
  for (toIx (2 :: Sint32) :: Ix 4) $ \ix -> do
    store x (fromIx ix)
    y <- deref x
    L.assert ((y <? 4) L..&& (y >=? 0))

m3 :: Module
m3 = package "foo3" (incl foo3)

-----------------------

foo4 :: Def ('[] :-> ())
foo4 = L.proc "foo4" $ body $ do
  x <- local (ival (1 :: Sint32))
  -- store x (7 .% 2)
  -- store x (4 .% 3)
  store x 1
  y <- deref x
  -- L.assert (y <? 2)
  L.assert (y ==? 1)

m4 :: Module
m4 = package "foo4" (incl foo4)

-----------------------

foo5 :: Def ('[] :-> ())
foo5 = L.proc "foo5" $ body $ do
  x <- local (ival (1 :: Sint32))
  -- for loops from 0 to n-1, inclusive
  for (toIx (9 :: Sint32) :: Ix 10) $ \ix -> do
    store x (fromIx ix)
    y <- deref x
    L.assert (y <=? 10)
  y <- deref x
  L.assert ((y ==? 8))

m5 :: Module
m5 = package "foo5" (incl foo5)

-----------------------

foo6 :: Def ('[Uint8] :-> ())
foo6 = L.proc "foo1" $ \x -> body $ do
  y <- local (ival (0 :: Uint8))
  ifte_ (x <? 3)
        (do a <- local (ival (9 :: Uint8))
            b <- deref a
            store y b
        )
        (do a <- local (ival (7 :: Uint8))
            b <- deref a
            store y b
        )
  z <- deref y
  L.assert (z <=? 9)
  L.assert (z >=? 7)

m6 :: Module
m6 = package "foo6" (incl foo6)

-----------------------

foo7 :: Def ('[Uint8, Uint8] :-> Uint8)
foo7 = L.proc "foo7" $ \x y ->
       requires (x + y <=? 255)
     $ body $ do
         ret (x + y)

m7 :: Module
m7 = package "foo7" (incl foo7)

-----------------------

foo8 :: Def ('[Uint8] :-> Uint8)
foo8 = L.proc "foo8" $ \x -> body $ do
  let y = x .% 3
  L.assert (y <? 4)
  ret y

m8 :: Module
m8 = package "foo8" (incl foo8)

-----------------------

[ivory|
struct foo
{ aFoo :: Stored Uint8
; bFoo :: Stored Uint8
}
|]

foo9 :: Def ('[Ref s (L.Struct "foo")] :-> ())
foo9 = L.proc "foo9" $ \f -> body $ do
  store (f ~> aFoo) 3
  store (f ~> bFoo) 1
  store (f ~> aFoo) 4
  x <- deref (f ~> aFoo)
  y <- deref (f ~> bFoo)
  L.assert (x ==? 4 L..&& y ==? 1)

m9 :: Module
m9 = package "foo9" (incl foo9)

-----------------------

foo10 :: Def ('[Uint8] :-> Uint8)
foo10 = L.proc "foo10" $ \x ->
        requires (x <? 10)
      $ ensures (\r -> r ==? x + 1)
      $ body $ do
        r <- assign $ x + 1
        ret r

m10 :: Module
m10 = package "foo10" (incl foo10)
    
-----------------------

foo11 :: Def ('[Ix 10] :-> ())
foo11 = L.proc "foo11" $ \n -> 
        requires (0 <=? n)
      $ requires (n <? 10)
      $ body $ do
          x <- local (ival (0 :: Sint8))
          for n $ \i -> do
            x' <- deref x
            store x $ x' + safeCast i

m11 :: Module
m11 = package "foo11" (incl foo11)

-----------------------

foo12 :: Def ('[Uint8] :-> Uint8)
foo12 = L.proc "foo12" $ \n -> 
        ensures (\r -> r ==? n)
      $ body $ do
          ifte_ (n ==? 0)
            (ret n)
            (do n' <- L.call foo12 (n-1)
                ret (n' + 1))

m12 :: Module
m12 = package "foo12" (incl foo12)

-----------------------

foo13 :: Def ('[Uint8, Uint8] :-> Uint8)
foo13 = L.proc "foo13" $ \x y -> 
        requires (x <=? 15)
      $ requires (y <=? 15)
      $ body $ ret (x * y)

m13 :: Module
m13 = package "foo13" (incl foo13)

-----------------------

foo14 :: Def ('[Uint8, Uint8] :-> Uint8)
foo14 = L.proc "foo14" $ \x y -> 
        body $ ret (x * y)

m14 :: Module
m14 = package "foo14" (incl foo14)

-----------------------

foo15 :: Def ('[Ix 10] :-> Uint8)
foo15 = L.proc "foo15" $ \n -> 
  ensures (\r -> r <=? 5) $
  body $ do
    n `times` \i -> do
      ifte_ (i >? 5) (ret 5) (ret $ safeCast i)

m15 :: Module
m15 = package "foo15" (incl foo15)