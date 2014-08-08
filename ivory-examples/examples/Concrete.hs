{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

--
-- C-like syntax for Ivory.
--
-- Copyright (C) 2014, Galois, Inc.
-- All rights reserved.
--

module Concrete where

import Prelude hiding (return)
import Ivory.Language

e :: IBool
e = (4::Sint32) >? 3

type SomeInt = Uint32

[ivory|

-- Define an expression
bar = 3 + 2;

-- Define a type alias
type Boo = int8_t;

-- Use them
Boo foo(Boo x) {
  return (bar + x);
}

-- Allocation on the stack.  Dereference is an expression.  All statements are
-- terminated with a ';'.
int32_t foo0() {
  alloc *x = 3;
  *x = 4;
  return *x + 4;
}

-- if-the-else blocks.  Braces are mandatory.
int32_t foo1() {
  if (true) {
    let a = 5;
    return a;
  }
  else {
    let b = 3;
    return b + 3;
  }
}

-- Void return statement.
void foo2() {
  if (true) {
    return;
  }
  else {
    return ;
  }
}

-- Allocate an array and index into it.  This function has type
--
-- foo6 :: Def ('[Ref s (Array 3 (Stored Uint32))] :-> Uint32)
--
uint32_t foo6(v *uint32_t[3] arr0) {
  alloc arr1[] = {1,2,3};
  map ix {
    *arr0 ! ix = *arr1 ! ix;
  }
  return *arr0 ! 1 ;
}
{ pre(*arr0 ! 1 > 0);
}

-- Boolean operators.  This function has type
--
-- foo7 :: Def ('[IBool, Uint32] :-> Uint32)
--
uint32_t foo7(bool b, uint32_t a) {
    return (b && !b ? a+3 : signum abs a - 4);
}

-- Function calls, with a return value and without.
uint32_t foo8(bool b, uint32_t a) {
    foo2();
    x = foo7 (b, a);
    foo7 (b, a);
    return (b && !b ? a+3 : signum abs a - x);
}

-- Local assignment.
uint32_t foo9(uint32_t a) {
  forever {
    let b = a + 3;
    return b;
  }
}

-- Memcopy.
void foo10(*uint32_t[3] r0, *uint32_t[3] r1) {
  memcpy r0 r1;
}

-- Const decorators.
uint32_t foo11(const *uint32_t i) {
  return *i;
}

-- Global allocation (G), stack allocation (S), and undetermined scope (var c).
uint8_t foo12(* uint8_t a, G*uint8_t b, * uint8_t c, S* uint8_t d) {
  *b = *a;
  return *b + *c + *d;
}

-- Field access from a struct pointer.
bool foo13(* struct Foo f) {
  return *(f &> aFoo);
}

-- Allocated on either the stack or globally, with user-provided type-variable (xx).
xx* uint32_t foo14(xx* struct Foo f) {
  let a = f &> aBar;
  let u = a ! 2;
  return u;
}

-- Pre and post conditions.
uint32_t foo15(uint32_t a, * struct Foo f, * struct Foo g) {
        return a;
}
{ pre(a < 4);
  pre(a > 0);
  post(return > 5);
  pre(* f &> aFoo && * g &> aFoo);
}

-- Stack allocated variable.
uint32_t foo16(S*uint32_t i) {
  return *i;
}
{ pre(*i > 3); }

-- Global allocated variable.
uint32_t foo17(G*uint32_t i) {
  return *i;
}

-- Structs
struct Foo
 { aBar :: Array 4 (Stored SomeInt)
 ; aFoo :: Stored IBool
 }

struct Boo
 { aFooVar :: Stored (Ix 3)
 }

-- Safe string structs
string struct ParamStruct 16

struct Foo2
  { foo2f :: Struct Foo
  }

-- Abstract structs
abstract struct fooStruct "foobar/foo.h"

-- Local naming
void mapProc(*uint8_t[4] arr, uint8_t x) {
  map ix {
    let v = arr ! ix;
    *v = *v + x;
  }
}

|]

testSizeOf :: Def ('[] :-> Uint8)
testSizeOf  = proc "test" (body (ret (sizeOf (Proxy :: Proxy (Struct "Foo")))))
