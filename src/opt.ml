open Ast

module Env = Map.Make(String)

let ($) f g x = f (g x)

let new_var = let count = ref 0 in function () -> (incr count; "_" ^ string_of_int !count)

exception Variable_undefined of string
exception Function_undefined of string
exception Wrong_number of string

let find_fun name env = try
  Env.find name env
with Not_found -> raise (Function_undefined name)

let find_var name env = try
  Env.find name env
with Not_found -> raise (Variable_undefined name)

let stdlib = List.fold_left (fun env (name, body) -> Env.add name body env) Env.empty
[]

(*
 * Rearrange the code tree so returning branches can be dealt with.
 *)
let rec leftify = function
| SSeq(SSeq(s1,s2),s3)         -> leftify (SSeq(s1, SSeq(s2,s3)))
| SSeq(s1, s2)                 -> SSeq(leftify s1, leftify s2)
| SFun(name, args, body, next) ->
    SFun(name, args, leftify body, leftify next)
| SWhile(b, s)    -> SWhile(b, leftify s)
| SIte(b, s1, s2) -> SIte(b, leftify s1, leftify s2)
| SVar(b, e, s)   -> SVar(b, e, leftify s)
| x -> x

(*
 * Rearrange the code so that instructions that follow an if-then-else
 * statement go in the branches of the statement instead. This actually
 * only needs being done when the ITE statement returns, so while
 * technically correct, one can view this implementation as inefficient.
 *)
let rec ite_friendly = function
| SSeq(SNop, s)             -> ite_friendly s
| SSeq(s, SNop)             -> ite_friendly s
| SSeq(SIte(b, s1, s2), s3) ->
  let ss1 = ite_friendly s1 in
  let ss2 = ite_friendly s2 in
  let ss3 = ite_friendly s3 in
  let lb = ite_friendly (leftify (SSeq (ss1,ss3))) in
  let rb = ite_friendly (leftify (SSeq (ss2,ss3))) in
  SIte(b, lb, rb)
| SSeq(s1,s2)
  -> (leftify (SSeq(ite_friendly s1, ite_friendly s2)))
| SWhile(b,s)                  -> SWhile(b, ite_friendly s)
| SVar(v,e,s)                  -> SVar(v,e, ite_friendly s)
| SIte(b,s1,s2)                -> SIte(b, ite_friendly s1, ite_friendly s2)
| SFun(name, args, body, next) ->
  SFun(name, args, ite_friendly body, ite_friendly next)
| x -> x

(*
 * Check if a branch of the code tree can return.
 *)
let rec returns = function
| SFun(_, _, body, next) -> (returns body) || (returns next)
| SAssign(_, _)          -> false
| SIte(_, s1, s2)        -> (returns s1) || (returns s2)
| SWhile(_, s)           -> returns s
| SSeq(s1, s2)           -> (returns s1) || (returns s2)
| SVar(_, e, s)          -> returns s
| SReturn(_)             -> true
| SNop                   -> false

(*
 * Remove from code the branches that should logically follow a return
 * statement, thus being never executed. The code should be prepared using
 * ite_friendly beforehand.
 *)
let rec remove_dead_branches = function
| SSeq(s1, s2) when returns s1 -> remove_dead_branches s1
| SSeq(s1, s2)             ->
    SSeq(remove_dead_branches s1, remove_dead_branches s2)
| SWhile(b,s)   -> SWhile(b, remove_dead_branches s)
| SVar(v,e,s)   -> SVar(v,e, remove_dead_branches s)
| SIte(b,s1,s2) ->
    SIte(b, remove_dead_branches s1, remove_dead_branches s2)
| SFun(name, args, body, next) ->
    SFun(name, args, remove_dead_branches body, remove_dead_branches next)
| x -> x

(*
 * Make the code tree ready for compilation.
 * This includes removing code that would possibly being executed after
 * a function has returned.
 *)
let precompile s = remove_dead_branches (ite_friendly (leftify s))

let rec inline_source funs vars = function
| SNop -> ISeq []
| SFun(f, args, body, next) ->
  inline_source (Env.add f (args, body) funs) vars next
| SAssign(names, App(f, arg_exprs)) -> begin try
    let args, body = find_fun f funs in
    let arg_names = List.map (new_var $ ignore) arg_exprs in
    let ans = List.mapi (fun i _ -> "__" ^ string_of_int i) names in
    let new_vars =
      List.fold_left2 (fun env k v -> Env.add k v env)
        (List.fold_left2 (fun env k1 k2 -> Env.add k1 (find_var k2 env) env) vars ans names)
        args arg_names
    in
    ISeq
      (List.fold_left2
        (fun l var expr -> inline_source funs new_vars (SAssign([var], expr)) :: l)
        [] args arg_exprs
      @ List.map (fun k -> IAssign(find_var k new_vars, Int 0, ())) names
      @ [inline_source funs new_vars body])
  with
  | Invalid_argument "List.fold_left2" -> raise (Wrong_number f)
end
| SReturn ans ->
  let l = List.mapi (fun i e ->
      let before, e_inline = inline_expr funs vars e in
      try
        ISeq (before @ [IAssign(Env.find ("__" ^ string_of_int i) vars, e_inline, ())])
      with
      | Not_found -> ISeq []
    ) ans
  in
  ISeq l
| SAssign(name :: _, e) ->
  let before, e_inline = inline_expr funs vars e in
  ISeq(before @ [IAssign(find_var name vars, e_inline, ())])
| SAssign([], _) -> assert false
| SVar(name, e, s) ->
  let before, e_inline = inline_expr funs vars e in
  let v = if Env.mem name vars then new_var () else name in
  ISeq(before @ [IAssign(v, e_inline, ()); inline_source funs (Env.add name v vars) s])
| SSeq(s1, s2) -> ISeq [inline_source funs vars s1; inline_source funs vars s2]
| SWhile(b, s) ->
  let before, b_inline = inline_bexpr funs vars b in
  ISeq(before @ [IWhile(b_inline, ISeq(inline_source funs vars s :: before), ())])
| SIte(b, s1, s2) ->
  let before, b_inline = inline_bexpr funs vars b in
  ISeq(before @ [IIte(b_inline, inline_source funs vars s1, inline_source funs vars s2, ())])

and inline_expr funs vars = function
| App(name, arg_exprs) ->
  let ans = new_var () in
  [inline_source funs (Env.add ans ans vars) (SAssign([ans], App(name, arg_exprs)))], Ident ans
| Op(Int n, Mul, e)
| Op(e, Mul, Int n) ->
  let rec mul n = if n = 1 then e else Op(e, Add, mul (n-1)) in
  inline_expr funs vars (mul n)
| Op(e1, Mul, e2) -> inline_expr funs vars (App("*", [e1; e2]))
| Op(e1, Div, e2) -> inline_expr funs vars (App("/", [e1; e2]))
| Op(e1, Mod, e2) -> inline_expr funs vars (App("%", [e1; e2]))
| Op(e1, op, e2) ->
  let before1, e1_inline = inline_expr funs vars e1
  and before2, e2_inline = inline_expr funs vars e2
  in
  before1 @ before2, Op(e1_inline, op, e2_inline)
| Ident name ->
  [], Ident (find_var name vars)
| Int n -> [], Int n

and inline_bexpr funs vars = function
| Cmp(e1, cmp, e2) ->
  let a, b = new_var (), new_var () in
  let before1, e1_inline = inline_expr funs vars e1
  and before2, e2_inline = inline_expr funs vars e2
  in
  before1 @ before2 @ [IAssign(a, e1_inline, ()); IAssign(b, e2_inline, ()); IComp(a, b, ())],
  begin match cmp with
  | Eq -> And(Not(Agent a), Not(Agent b))
  | Neq -> Or(Agent a, Agent b)
  | Lt -> Agent b
  | Lte -> Not(Agent a)
  | Gt -> Agent a
  | Gte -> Not(Agent b)
  end
| And(b1, b2) ->
  let before1, b1_inline = inline_bexpr funs vars b1
  and before2, b2_inline = inline_bexpr funs vars b2
  in
  before1 @ before2, And(b1_inline, b2_inline)
| Or(b1, b2) ->
  let before1, b1_inline = inline_bexpr funs vars b1
  and before2, b2_inline = inline_bexpr funs vars b2
  in
  before1 @ before2, Or(b1_inline, b2_inline)
| Not(b) ->
  let before, b_inline = inline_bexpr funs vars b in
  before, Not(b_inline)
| Agent a -> assert false

let rec flatten i =
  let rec aux = function
  | ISeq l -> (List.flatten (List.map aux l))
  | IIte(b, i1, i2, tag) -> [IIte(b, flatten i1, flatten i2, tag)]
  | IWhile(b, i, tag) -> [IWhile(b, flatten i, tag)]
  | IPar l -> [IPar(List.map flatten l)]
  | IAssign(v, e, tag) -> [IAssign(v, e, tag)]
  | IComp(a, b, tag) -> [IComp(a, b, tag)]
  in
  match aux i with
  | [x] -> x
  | l -> ISeq l

module S = Set.Make(String)

let rec base_vars vars = function
| SFun (_, _, _, s) -> base_vars vars s
| SVar (name, _, s) -> base_vars (S.add name vars) s
| SSeq (a, b) -> base_vars (base_vars vars a) b
| SAssign _
| SIte _
| SWhile _
| SReturn _
| SNop -> vars

let rec fixpoint (=) f x =
  let y = f x in
  if y = x then y else fixpoint (=) f y

let rec free_expr vars = function
| Ident name -> S.add name vars
| Int _ -> vars
| Op(e1, _, e2) -> free_expr (free_expr vars e1) e2
| App _ -> assert false

let rec free_bexpr vars = function
| Agent name -> S.add name vars
| Or(b1, b2) | And(b1, b2) -> free_bexpr (free_bexpr vars b1) b2
| Not(b) -> free_bexpr vars b
| Cmp _ -> assert false

let rec alive vars = function
| IAssign(name, value, _) when not (S.mem name vars) -> ISeq [], vars
| IAssign(name, value, _) -> IAssign(name, value, vars), free_expr (S.remove name vars) value
| IComp(a, b, _) -> IComp(a, b, vars), vars
| IIte(b, i1, i2, _) ->
  let tagged_i1, vars_i1 = alive vars i1
  and tagged_i2, vars_i2 = alive vars i2
  in
  IIte(b, tagged_i1, tagged_i2, vars), free_bexpr (S.union vars_i1 vars_i2) b
| IWhile(b, i, _) ->
  let v = free_bexpr vars b in
  let s = fixpoint S.equal (fun s -> let _, t = alive s i in S.union t v) v in
  let tagged, _ = alive s i in
  IWhile(b, tagged, s), s
| ISeq l ->
  let l, v = List.fold_right (fun i (t, v) -> let h, v = alive v i in h :: t, v) l ([], vars) in
  ISeq l, v
| IPar l ->
  let l, v =
    List.fold_left
      (fun (t, v1) i -> let h, v2 = alive vars i in h :: t, S.union v1 v2)
      ([], S.empty) l
  in
  IPar l, v
