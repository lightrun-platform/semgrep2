(* Yoann Padioleau, Iago Abal
 *
 * Copyright (C) 2019-2024 Semgrep Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)
open Common
open IL
module G = AST_generic
module F = IL
module D = Dataflow_core
module Var_env = Dataflow_var_env
module VarMap = Var_env.VarMap
module PM = Pattern_match
module R = Rule
module S = Taint_shape
module LV = IL_helpers
module T = Taint
module Sig = Taint_sig
module Lval_env = Taint_lval_env
module Taints = T.Taint_set
module TM = Taint_smatch

(* TODO: Rename things to make clear that there are "sub-matches" and there are
 * "best matches". *)

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Tainting dataflow analysis.
 *
 * - This is a rudimentary taint analysis in some ways, but rather complex in
 *   other ways... We don't do alias analysis, and inter-procedural support
 *   (for DeepSemgrep) still doesn't cover some common cases. On the other hand,
 *   almost _anything_ can be a source/sanitizer/sink, we have taint propagators,
 *   etc.
 * - It is a MAY analysis, it finds *potential* bugs (the tainted path could not
 *   be feasible in practice).
 * - Field sensitivity is limited to l-values of the form x.a.b.c, see module
 *   Taint_lval_env and check_tainted_lval for more details. Very coarse grained
 *   otherwise, e.g. `x[i] = tainted` will taint the whole array,
 *
 * old: This was originally in src/analyze, but it now depends on
 *      Pattern_match, so it was moved to src/engine.
 *)

module DataflowX = Dataflow_core.Make (struct
  type node = F.node
  type edge = F.edge
  type flow = (node, edge) CFG.t

  let short_string_of_node n = Display_IL.short_string_of_node_kind n.F.n
end)

module SMap = Map.Make (String)

let base_tag_strings = [ __MODULE__; "taint" ]
let _tags = Logs_.create_tags base_tag_strings
let sigs = Logs_.create_tags (base_tag_strings @ [ "taint_sigs" ])
let transfer = Logs_.create_tags (base_tag_strings @ [ "taint_transfer" ])
let error = Logs_.create_tags (base_tag_strings @ [ "error" ])

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type var = Var_env.var

type a_propagator = {
  kind : [ `From | `To ];
  prop : R.taint_propagator;
  var : var;
}

type config = {
  filepath : string;
  rule_id : Rule_ID.t;
  track_control : bool;
  is_source : G.any -> R.taint_source TM.t list;
  is_propagator : AST_generic.any -> a_propagator TM.t list;
  is_sink : G.any -> R.taint_sink TM.t list;
  is_sanitizer : G.any -> R.taint_sanitizer TM.t list;
      (* NOTE [is_sanitizer]:
       * A sanitizer is more "extreme" than you may expect. When a piece of code is
       * "sanitized" Semgrep will just not check it. For example, something like
       * `sanitize(sink(tainted))` will not yield any finding.
       * *)
  unify_mvars : bool;
  handle_results : var option -> Sig.result list -> Lval_env.t -> unit;
}

type mapping = Lval_env.t D.mapping

(* HACK: Tracks tainted functions intrafile. *)
type fun_env = (var, Taints.t) Hashtbl.t
type java_props_cache = (string * G.SId.t, IL.name) Hashtbl.t

let mk_empty_java_props_cache () = Hashtbl.create 30

(* THINK: Separate read-only enviroment into a new a "cfg" type? *)
type env = {
  lang : Lang.t;
  options : Rule_options.t;
  config : config;
  fun_name : var option;
  lval_env : Lval_env.t;
  best_matches : TM.Best_matches.t;
  java_props : java_props_cache;
}

(*****************************************************************************)
(* Hooks *)
(*****************************************************************************)

let hook_function_taint_signature = ref None
let hook_find_attribute_in_class = ref None
let hook_check_tainted_at_exit_sinks = ref None

(*****************************************************************************)
(* Options *)
(*****************************************************************************)

let propagate_through_functions env =
  (not env.options.taint_assume_safe_functions)
  && not env.options.taint_only_propagate_through_assignments

let propagate_through_indexes env =
  (not env.options.taint_assume_safe_indexes)
  && not env.options.taint_only_propagate_through_assignments

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let ( let+ ) x f =
  match x with
  | None -> []
  | Some x -> f x

let ( let& ) x f =
  match x with
  | None -> Taints.empty
  | Some x -> f x

let _show_fun_exp fun_exp =
  match fun_exp with
  | { e = Fetch { base = Var func; rev_offset = [] }; _ } -> fst func.ident
  | { e = Fetch { base = Var obj; rev_offset = [ { o = Dot method_; _ } ] }; _ }
    ->
      Printf.sprintf "%s.%s" (fst obj.ident) (fst method_.ident)
  | _ -> "<FUNC>"

let map_check_expr env check_expr xs =
  let rev_taints_and_shapes, lval_env =
    xs
    |> List.fold_left
         (fun (rev_taints_and_shapes, lval_env) x ->
           let taints, shape, lval_env = check_expr { env with lval_env } x in
           ((taints, shape) :: rev_taints_and_shapes, lval_env))
         ([], env.lval_env)
  in
  (List.rev rev_taints_and_shapes, lval_env)

let union_map_taints_and_vars env check xs =
  let taints, lval_env =
    xs
    |> List.fold_left
         (fun (taints_acc, lval_env) x ->
           let taints, shape, lval_env = check { env with lval_env } x in
           let taints_acc =
             taints_acc |> Taints.union taints
             |> Taints.union (S.gather_all_taints_in_shape shape)
           in
           (taints_acc, lval_env))
         (Taints.empty, env.lval_env)
  in
  let taints =
    if env.options.taint_only_propagate_through_assignments then Taints.empty
    else taints
  in
  (taints, lval_env)

let gather_all_taints_in_args_taints args_taints =
  args_taints
  |> List.fold_left
       (fun acc arg ->
         match arg with
         | Named (_, (_, shape))
         | Unnamed (_, shape) ->
             S.gather_all_taints_in_shape shape |> Taints.union acc)
       Taints.empty

let any_is_best_sanitizer env any =
  env.config.is_sanitizer any
  |> List.filter (fun (m : R.taint_sanitizer TM.t) ->
         (not m.spec.sanitizer_exact) || TM.is_best_match env.best_matches m)

(* TODO: We could return source matches already split by `by-side-effect` here ? *)
let any_is_best_source ?(is_lval = false) env any =
  env.config.is_source any
  |> List.filter (fun (m : R.taint_source TM.t) ->
         (* Remove sources that should match exactly but do not here. *)
         match m.spec.source_by_side_effect with
         | Only -> is_lval && TM.is_exact m
         (* 'Yes' should probably require an exact match like 'Only' but for
          *  backwards compatibility we keep it this way. *)
         | Yes
         | No ->
             (not m.spec.source_exact) || TM.is_best_match env.best_matches m)

let any_is_best_sink env any =
  env.config.is_sink any
  |> List.filter (fun (tm : R.taint_sink TM.t) ->
         (* at-exit sinks are handled in 'check_tainted_at_exit_sinks' *)
         (not tm.spec.sink_at_exit) && TM.is_best_match env.best_matches tm)

let orig_is_source config orig = config.is_source (any_of_orig orig)

let orig_is_best_source env orig : R.taint_source TM.t list =
  any_is_best_source env (any_of_orig orig)

let orig_is_sanitizer config orig = config.is_sanitizer (any_of_orig orig)

let orig_is_best_sanitizer env orig =
  any_is_best_sanitizer env (any_of_orig orig)

let orig_is_sink config orig = config.is_sink (any_of_orig orig)
let orig_is_best_sink env orig = any_is_best_sink env (any_of_orig orig)

let any_of_lval lval =
  match lval with
  | { rev_offset = { oorig; _ } :: _; _ } -> any_of_orig oorig
  | { base = Var var; rev_offset = [] } ->
      let _, tok = var.ident in
      G.Tk tok
  | { base = VarSpecial (_, tok); rev_offset = [] } -> G.Tk tok
  | { base = Mem e; rev_offset = [] } -> any_of_orig e.eorig

let lval_is_source env lval =
  any_is_best_source ~is_lval:true env (any_of_lval lval)

let lval_is_best_sanitizer env lval =
  any_is_best_sanitizer env (any_of_lval lval)

let lval_is_sink env lval =
  (* TODO: This should be = any_is_best_sink env (any_of_lval lval)
   *    but see tests/rules/TODO_taint_messy_sink. *)
  env.config.is_sink (any_of_lval lval)
  |> List.filter (fun (tm : R.taint_sink TM.t) ->
         (* at-exit sinks are handled in 'check_tainted_at_exit_sinks' *)
         not tm.spec.sink_at_exit)

let taints_of_matches env ~incoming sources =
  let control_sources, data_sources =
    sources
    |> List.partition (fun (m : R.taint_source TM.t) -> m.spec.source_control)
  in
  (* THINK: It could make sense to merge `incoming` with `control_incoming`, so
   * a control source could influence a data source and vice-versa. *)
  let data_taints =
    data_sources
    |> List_.map (fun x -> (x.TM.spec_pm, x.spec))
    |> T.taints_of_pms ~incoming
  in
  let control_incoming = Lval_env.get_control_taints env.lval_env in
  let control_taints =
    control_sources
    |> List_.map (fun x -> (x.TM.spec_pm, x.spec))
    |> T.taints_of_pms ~incoming:control_incoming
  in
  let lval_env = Lval_env.add_control_taints env.lval_env control_taints in
  (data_taints, lval_env)

let report_results env results =
  if results <> [] then
    env.config.handle_results env.fun_name results env.lval_env

let unify_mvars_sets env mvars1 mvars2 =
  let xs =
    List.fold_left
      (fun xs_opt (mvar, mval) ->
        let* xs = xs_opt in
        match List.assoc_opt mvar mvars2 with
        | None -> Some ((mvar, mval) :: xs)
        | Some mval' ->
            if Matching_generic.equal_ast_bound_code env.options mval mval' then
              Some ((mvar, mval) :: xs)
            else None)
      (Some []) mvars1
  in
  let ys =
    List.filter (fun (mvar, _) -> not @@ List.mem_assoc mvar mvars1) mvars2
  in
  Option.map (fun xs -> xs @ ys) xs

let sink_biased_union_mvars source_mvars sink_mvars =
  let source_mvars' =
    List.filter
      (fun (mvar, _) -> not @@ List.mem_assoc mvar sink_mvars)
      source_mvars
  in
  Some (source_mvars' @ sink_mvars)

(* Takes the bindings of multiple taint sources and filters the bindings ($MVAR, MVAL)
 * such that either $MVAR is bound by a single source, or all MVALs bounds to $MVAR
 * can be unified. *)
let merge_source_mvars env bindings =
  let flat_bindings = List.concat bindings in
  let bindings_tbl =
    flat_bindings
    |> List_.map (fun (mvar, _) -> (mvar, None))
    |> List.to_seq |> Hashtbl.of_seq
  in
  flat_bindings
  |> List.iter (fun (mvar, mval) ->
         match Hashtbl.find_opt bindings_tbl mvar with
         | None ->
             (* This should only happen if we've previously found that
                there is a conflict between bound values at `mvar` in
                the sources.
             *)
             ()
         | Some None ->
             (* This is our first time seeing this value, let's just
                add it in.
             *)
             Hashtbl.replace bindings_tbl mvar (Some mval)
         | Some (Some mval') ->
             if
               not
                 (Matching_generic.equal_ast_bound_code env.options mval mval')
             then Hashtbl.remove bindings_tbl mvar);
  (* After this, the only surviving bindings should be those where
     there was no conflict between bindings in different sources.
  *)
  bindings_tbl |> Hashtbl.to_seq |> List.of_seq
  |> List_.map_filter (fun (mvar, mval_opt) ->
         match mval_opt with
         | None ->
             (* This actually shouldn't really be possible, every
                binding should either not exist, or contain a value
                if there's no conflict. But whatever. *)
             None
         | Some mval -> Some (mvar, mval))

(* Merge source's and sink's bound metavariables. *)
let merge_source_sink_mvars env source_mvars sink_mvars =
  if env.config.unify_mvars then
    (* This used to be the default, but it turned out to be confusing even for
     * r2c's security team! Typically you think of `pattern-sources` and
     * `pattern-sinks` as independent. We keep this option mainly for
     * backwards compatibility, it may be removed later on if no real use
     * is found. *)
    unify_mvars_sets env source_mvars sink_mvars
  else
    (* The union of both sets, but taking the sink mvars in case of collision. *)
    sink_biased_union_mvars source_mvars sink_mvars

let partition_sources_by_side_effect sources_matches =
  sources_matches
  |> Either_.partition_either3 (fun (m : R.taint_source TM.t) ->
         match m.spec.source_by_side_effect with
         | R.Only -> Left3 m
         (* A 'Yes' should be a 'Yes' regardless of whether the match is exact...
          * Whether the match is exact or not is/should be taken into consideration
          * later on. Same as for 'Only'. But for backwards-compatibility we keep
          * it this way for now. *)
         | R.Yes when TM.is_exact m -> Middle3 m
         | R.Yes
         | R.No ->
             Right3 m)
  |> fun (only, yes, no) -> (`Only only, `Yes yes, `No no)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

let type_of_lval env lval =
  match lval with
  | { base = Var x; rev_offset = [] } ->
      Typing.resolved_type_of_id_info env.lang x.id_info
  | { base = _; rev_offset = { o = Dot fld; _ } :: _ } ->
      Typing.resolved_type_of_id_info env.lang fld.id_info
  | __else__ -> Type.NoType

let type_of_expr env e =
  match e.eorig with
  | SameAs eorig -> Typing.type_of_expr env.lang eorig |> fst
  | __else__ -> Type.NoType

(* We only check this at a few key places to avoid calling `type_of_expr` too
 * many times which could be bad for perf (but haven't properly benchmarked):
 * - assignments
 * - return's
 * - function calls and their actual arguments
 * TODO: Ideally we add an `e_type` field and have a type-inference pass to
 *  fill it in, so that every expression has its known type available without
 *  extra cost.
 *)
let drop_taints_if_bool_or_number (options : Rule_options.t) taints ty =
  match ty with
  | Type.(Builtin Bool) when options.taint_assume_safe_booleans -> Taints.empty
  | Type.(Builtin (Int | Float | Number)) when options.taint_assume_safe_numbers
    ->
      Taints.empty
  | __else__ -> taints

(* Calls to 'type_of_expr' seem not to be cheap and even though we tried to limit the
 * number of these calls being made, doing them unconditionally caused a slowdown of
 * ~25% in a ~dozen repos in our stress-test-monorepo. We should just not call
 * 'type_of_expr' unless at least one of the taint_assume_safe_{booleans,numbers} has
 * been set, so rules that do not use these options remain unaffected. Long term we
 * should make type_of_expr less costly.
 *)
let check_type_and_drop_taints_if_bool_or_number env taints type_of_x x =
  if
    (env.options.taint_assume_safe_booleans
   || env.options.taint_assume_safe_numbers)
    && not (Taints.is_empty taints)
  then
    match type_of_x env x with
    | Type.Function (_, return_ty) ->
        drop_taints_if_bool_or_number env.options taints return_ty
    | ty -> drop_taints_if_bool_or_number env.options taints ty
  else taints

(*****************************************************************************)
(* Labels *)
(*****************************************************************************)

(* This function is used to convert some taint thing we're holding
   to one which has been propagated to a new label.
   See [handle_taint_propagators] for more.
*)
let propagate_taint_to_label replace_labels label (taint : T.taint) =
  let new_orig =
    match (taint.orig, replace_labels) with
    (* if there are no replaced labels specified, we will replace
       indiscriminately
    *)
    | Src src, None -> T.Src { src with label }
    | Src src, Some replace_labels when List.mem src.T.label replace_labels ->
        T.Src { src with label }
    | ((Src _ | Var _ | Control) as orig), _ -> orig
  in
  { taint with orig = new_orig }

(*****************************************************************************)
(* Reporting results *)
(*****************************************************************************)

(* Potentially produces a result from incoming taints + call traces to a sink.
   Note that, while this sink has a `requires` and incoming labels,
   we decline to solve this now!
   We will figure out how many actual Semgrep findings are generated
   when this information is used, later.
*)
let results_of_tainted_sink env taints_with_traces (sink : Sig.sink) :
    Sig.result list =
  match taints_with_traces with
  | [] -> []
  | _ :: _ -> (
      (* We cannot check whether we satisfy the `requires` here.
         This is because this sink may be inside of a function, meaning that
         argument taint can reach it, which can only be instantiated at the
         point where we call the function.
         So we record the `requires` within the taint finding, and evaluate
         the formula later, when we extract the PMs
      *)
      let { Sig.pm = sink_pm; rule_sink = ts } = sink in
      let taints_and_bindings =
        taints_with_traces
        |> List_.map (fun ({ Sig.taint; _ } as item) ->
               let bindings =
                 match taint.T.orig with
                 | T.Src source ->
                     let src_pm, _ = T.pm_of_trace source.call_trace in
                     src_pm.PM.env
                 | Var _
                 | Control ->
                     []
               in
               let new_taint = { taint with tokens = List.rev taint.tokens } in
               ({ item with taint = new_taint }, bindings))
      in
      (* If `unify_mvars` is set, then we will just do the previous behavior,
         and emit a finding for every single source coming into the sink.
         This will mean we don't regress on `taint_unify_mvars: true` rules.

         This is problematic because there may be many sources, all of which do not
         unify with each other, but which unify with the sink.
         If we did as below and unified them all with each other, we would sometimes
         produce no findings when we should.
      *)
      (* The same will happen if our sink does not have an explicit `requires`.

         This is because our behavior in the second case will remove metavariables
         from the finding, if they conflict in the sources.

         This can lead to a loss of metavariable interpolation in the finding message,
         even for "vanilla" taint mode rules that don't use labels, for instance if
         we had two instances of the source

         foo($X)

         reaching a sink, where in both instances, `$X` is not the same. The current
         behavior is that one of the `$X` bindings is chosen arbitrarily. We will
         try to keep this behavior here.
      *)
      if env.config.unify_mvars || Option.is_none sink.rule_sink.sink_requires
      then
        taints_and_bindings
        |> List_.map_filter (fun (t, bindings) ->
               let* merged_env =
                 merge_source_sink_mvars env sink_pm.PM.env bindings
               in
               Some
                 (Sig.ToSink
                    {
                      taints_with_precondition = ([ t ], R.get_sink_requires ts);
                      sink;
                      merged_env;
                    }))
      else
        match
          taints_and_bindings |> List_.map snd |> merge_source_mvars env
          |> merge_source_sink_mvars env sink_pm.PM.env
        with
        | None -> []
        | Some merged_env ->
            [
              Sig.ToSink
                {
                  taints_with_precondition =
                    (List_.map fst taints_and_bindings, R.get_sink_requires ts);
                  sink;
                  merged_env;
                };
            ])

(* Produces a finding for every unifiable source-sink pair. *)
let results_of_tainted_sinks env taints sinks : Sig.result list =
  let taints =
    let control_taints = Lval_env.get_control_taints env.lval_env in
    taints |> Taints.union control_taints
  in
  if Taints.is_empty taints then []
  else
    sinks
    |> List.concat_map (fun sink ->
           (* This is where all taint results start. If it's interproc,
              the call trace will be later augmented into the Call variant,
              but it starts out here as just a PM variant.
           *)
           let taints_with_traces =
             taints |> Taints.elements
             |> List_.map (fun t ->
                    { Sig.taint = t; sink_trace = T.PM (sink.Sig.pm, ()) })
           in
           results_of_tainted_sink env taints_with_traces sink)

let results_of_tainted_return taints shape return_tok : Sig.result list =
  if S.taints_and_shape_are_relevant taints shape then
    let taints = taints |> Taints.union (S.gather_all_taints_in_shape shape) in
    let taint_list =
      taints |> Taints.elements
      |> List_.map (fun t -> { t with T.tokens = List.rev t.T.tokens })
    in
    [ Sig.ToReturn (taint_list, return_tok) ]
  else []

let check_orig_if_sink env ?filter_sinks orig taints shape =
  (* NOTE(gather-all-taints):
   * A sink is something opaque to us, e.g. consider sink(["ok", "tainted"]),
   * `sink` could potentially access "tainted". So we must take into account
   * all taints reachable through its shape.
   *)
  let taints = taints |> Taints.union (S.gather_all_taints_in_shape shape) in
  let sinks = orig_is_best_sink env orig in
  let sinks =
    match filter_sinks with
    | None -> sinks
    | Some sink_pred -> sinks |> List.filter sink_pred
  in
  let sinks = sinks |> List_.map TM.sink_of_match in
  let results = results_of_tainted_sinks env taints sinks in
  report_results env results

(*****************************************************************************)
(* Miscellaneous large functions *)
(*****************************************************************************)

let find_pos_in_actual_args args_taints fparams =
  let pos_args_taints, named_args_taints =
    List.partition_map
      (function
        | Unnamed taints -> Left taints
        | Named (id, taints) -> Right (id, taints))
      args_taints
  in
  let named_arg_map =
    named_args_taints
    |> List.fold_left
         (fun xmap ((s, _), taint) -> SMap.add s taint xmap)
         SMap.empty
  in
  let name_to_taints = Hashtbl.create 10 in
  let idx_to_taints = Hashtbl.create 10 in
  (* We first process the named arguments, and then positional arguments.
   *)
  let remaining_params =
    (* Here, we take all the named arguments and remove them from the list of parameters.
     *)
    List_.fold_right
      (fun param acc ->
        match param with
        | G.Param { pname = Some (s', _); _ } -> (
            match SMap.find_opt s' named_arg_map with
            | Some taints ->
                (* If this parameter is one of our arguments, insert a mapping and then remove it
                   from the list of remaining parameters.*)
                Hashtbl.add name_to_taints s' taints;
                acc
                (* Otherwise, it has not been consumed, so keep it in the remaining parameters.*)
            | None -> param :: acc (* Same as above. *))
        | __else__ -> param :: acc)
      (Tok.unbracket fparams) []
  in
  let _ =
    (* We then process all of the positional arguments in order of the remaining parameters.
     *)
    pos_args_taints
    |> List.fold_left
         (fun (i, remaining_params) taints ->
           match remaining_params with
           | [] ->
               Logs.debug (fun m ->
                   m ~tags:error
                     "More args to function than there are positional \
                      arguments in function signature");
               (i + 1, [])
           | _ :: rest ->
               Hashtbl.add idx_to_taints i taints;
               (i + 1, rest))
         (0, remaining_params)
  in
  fun ({ name = s; index = i } : Taint.arg) ->
    let taint_opt =
      match
        (Hashtbl.find_opt name_to_taints s, Hashtbl.find_opt idx_to_taints i)
      with
      | Some taints, _ -> Some taints
      | _, Some taints -> Some taints
      | __else__ -> None
    in
    if Option.is_none taint_opt then
      Logs.debug (fun m ->
          m ~tags:error
            "Cannot match taint variable with function arguments (%i: %s)" i s);
    taint_opt

let fix_poly_taint_with_field env lval xtaint =
  let type_of_il_offset il_offset =
    match il_offset.IL.o with
    | Dot n -> !(n.id_info.id_type)
    | Index _ -> None
  in
  (* TODO: Aren't we missing here C# and Go ? *)
  if env.lang =*= Lang.Java || Lang.is_js env.lang || env.lang =*= Lang.Python
  then
    match xtaint with
    | `Sanitized
    | `Clean
    | `None ->
        xtaint
    | `Tainted taints -> (
        match lval.rev_offset with
        | o :: _ -> (
            match (type_of_il_offset o, T.offset_of_IL o) with
            | Some { t = TyFun _; _ }, _ ->
                (* We have an l-value like `o.f` where `f` has a function type,
                 * so it's a method call, we return nothing here. We cannot just
                 * return `xtaint`, which is the taint of `o` in the environment;
                 * whether that taint propagates or not is determined in
                 * 'check_tainted_instr'/'Call'. Otherwise, if `o` had taint var
                 * 'o@i', the call `o.getX()` would have taints '{o@i, o@i.x}'
                 * when it should only have taints '{o@i.x}'. *)
                `None
            | _, Oany ->
                (* Cannot handle this offset. *)
                xtaint
            | __any__, ((Ofld _ | Ostr _ | Oint _) as o) ->
                (* Not a method call (to the best of our knowledge) or
                 * an unresolved Java `getX` method. *)
                let taints' =
                  taints
                  |> Taints.map (fun taint ->
                         match taint.orig with
                         | Var ({ offset; _ } as lval)
                           when (* If the offset we are trying to take is already in the
                                   list of offsets, don't append it! This is so we don't
                                   never-endingly loop the dataflow and make it think the
                                   Arg taint is never-endingly changing.

                                   For instance, this code example would previously loop,
                                   if `x` started with an `Arg` taint:
                                   while (true) { x = x.getX(); }
                                *)
                                (not (List.mem o offset))
                                && (* For perf reasons we don't allow offsets to get too long.
                                    * Otherwise in a long chain of function calls where each
                                    * function adds some offset, we could end up a very large
                                    * amount of polymorphic taint.
                                    * This actually happened with rule
                                    * semgrep.perf.rules.express-fs-filename from the Pro
                                    * benchmarks, and file
                                    * WebGoat/src/main/resources/webgoat/static/js/libs/ace.js.
                                    *
                                    * TODO: This is way less likely to happen if we had better
                                    *   type info and we used to remove taint, e.g. if Boolean
                                    *   and integer expressions didn't propagate taint. *)
                                List.length offset
                                < Limits_semgrep.taint_MAX_POLY_OFFSET ->
                             let lval' =
                               { lval with offset = lval.offset @ [ o ] }
                             in
                             { taint with orig = Var lval' }
                         | Src _
                         | Var _
                         | Control ->
                             taint)
                in
                `Tainted taints')
        | [] -> xtaint)
  else xtaint

(*****************************************************************************)
(* Tainted *)
(*****************************************************************************)

let sanitize_lval_by_side_effect lval_env sanitizer_pms lval =
  let lval_is_now_safe =
    (* If the l-value is an exact match (overlap > 0.99) for a sanitizer
     * annotation, then we infer that the l-value itself has been updated
     * (presumably by side-effect) and is no longer tainted. We will update
     * the environment (i.e., `lval_env') accordingly. *)
    List.exists
      (fun (m : R.taint_sanitizer TM.t) ->
        m.spec.sanitizer_by_side_effect && TM.is_exact m)
      sanitizer_pms
  in
  if lval_is_now_safe then Lval_env.clean lval_env lval else lval_env

(* Check if an expression is sanitized, if so returns `Some' and otherise `None'.
   If the expression is of the form `x.a.b.c` then we try to sanitize it by
   side-effect, in which case this function will return a new lval_env. *)
let exp_is_sanitized env exp =
  match orig_is_best_sanitizer env exp.eorig with
  (* See NOTE [is_sanitizer] *)
  | [] -> None
  | sanitizer_pms -> (
      match exp.e with
      | Fetch lval ->
          Some (sanitize_lval_by_side_effect env.lval_env sanitizer_pms lval)
      | __else__ -> Some env.lval_env)

(* Checks if `thing' is a propagator `from' and if so propagates `taints' through it.
   Checks if `thing` is a propagator `'to' and if so fetches any taints that had been
   previously propagated. Returns *only* the newly propagated taint. *)
let handle_taint_propagators env thing taints shape =
  (* We propagate taints via an auxiliary variable (the propagator id). This is
   * simple but it has limitations. It works well to propagate "forward" and,
   * within an instruction node, to propagate in the order in which we visit the
   * subexpressions. E.g. in `x.f(y,z)` we can easily propagate taint from `y` or
   * `z` to `x`, or from `y` to `z`.
   *
   * So, how to propagate taint from `x` to `y` or `z`, or from `z` to `y` ?
   * In Pro, we do it by recording them as "pending" (see
   * 'Taint_lval_env.pending_propagation_dests'). The problem with that kind of
   * "delayed" propagation is that it **only** works by side-effect, but not at
   * the very location of the destination. So we can propagate taint by side-effect
   * from `z` to `y` in `x.f(y,z)`, but the `y` occurrence that is the actual
   * destination (i.e. the `$TO`) will not have the taints coming from `z`, only
   * the subsequent occurrences of `y` will.
   * TODO: To support that, we may need to introduce taint variables that we can
   *       later substitute, like we do for labels.
   * *)
  let taints = taints |> Taints.union (S.gather_all_taints_in_shape shape) in
  let lval_env = env.lval_env in
  let propagators =
    let any =
      match thing with
      | `Lval lval -> any_of_lval lval
      | `Exp exp -> any_of_orig exp.eorig
      | `Ins ins -> any_of_orig ins.iorig
    in
    env.config.is_propagator any
  in
  let propagate_froms, propagate_tos =
    List.partition (fun p -> p.TM.spec.kind =*= `From) propagators
  in
  let lval_env =
    (* `thing` is the source (the "from") of propagation, we add its taints to
     * the environment. *)
    List.fold_left
      (fun lval_env prop ->
        (* Only propagate if the current set of taint labels can satisfy the
           propagator's requires precondition.
        *)
        (* TODO(brandon): Interprocedural propagator labels
           This is trickier than I thought. You have to augment the Arg taints
           with preconditions as well, and allow conjunction, because when you
           replace an Arg taint with a precondition, all the produced taints
           inherit the precondition. There's not an easy way to express this
           in the type right now.

           More concretely, the existence of labeled propagators means that
           preconditions can be attached to arbitrary taint. This is because
           if we have a taint that is being propagated with a `requires`, then
           that taint now has a precondition on that `requires` being true. This
           taint might also be an `Arg` taint, meaning that `Arg` taints can
           have preconditions.

           This is more than just a simple type-level change because when `Arg`s
           have preconditions, what happens for substitution? Say I want to
           replace an `Arg x` taint with [t], that is, a single taint. Well,
           that taint `t` might itself have a precondition. That means that we
           now have a taint which is `t`, substituted for `Arg x`, but also
           inheriting `Arg x`'s precondition. Our type for preconditions doesn't
           allow arbitrary conjunction of preconditions like that, so this is
           more pervasive of a change.

           I'll come back to this later.
        *)
        match
          T.solve_precondition ~ignore_poly_taint:false ~taints
            (R.get_propagator_precondition prop.TM.spec.prop)
        with
        | Some true ->
            (* If we have an output label, change the incoming taints to be
               of the new label.
               Otherwise, keep them the same.
            *)
            let new_taints =
              match prop.TM.spec.prop.propagator_label with
              | None -> taints
              | Some label ->
                  Taints.map
                    (propagate_taint_to_label
                       prop.spec.prop.propagator_replace_labels label)
                    taints
            in
            Lval_env.propagate_to prop.spec.var new_taints lval_env
        | Some false
        | None ->
            lval_env)
      lval_env propagate_froms
  in
  let taints_propagated, lval_env =
    (* `thing` is the destination (the "to") of propagation. we collect all the
     * incoming taints by looking for the propagator ids in the environment. *)
    List.fold_left
      (fun (taints_in_acc, lval_env) prop ->
        let opt_propagated, lval_env =
          Lval_env.propagate_from prop.TM.spec.var lval_env
        in
        let taints_from_prop =
          match opt_propagated with
          | None -> Taints.empty
          | Some taints -> taints
        in
        let lval_env =
          if prop.spec.prop.propagator_by_side_effect then
            match thing with
            (* If `thing` is an l-value of the form `x.a.b.c`, then taint can be
             *  propagated by side-effect. A pattern-propagator may use this to
             * e.g. propagate taint from `x` to `y` in `f(x,y)`, so that
             * subsequent uses of `y` are tainted if `x` was previously tainted. *)
            | `Lval lval ->
                if Option.is_some opt_propagated then
                  lval_env |> Lval_env.add lval taints_from_prop
                else
                  (* If we did not find any taint to be propagated, it could
                   * be because we have not encountered the 'from' yet, so we
                   * add the 'lval' to a "pending" queue. *)
                  lval_env |> Lval_env.pending_propagation prop.TM.spec.var lval
            | `Exp _
            | `Ins _ ->
                lval_env
          else lval_env
        in
        (Taints.union taints_in_acc taints_from_prop, lval_env))
      (Taints.empty, lval_env) propagate_tos
  in
  (taints_propagated, lval_env)

let find_lval_taint_sources env incoming_taints lval =
  let taints_of_pms env = taints_of_matches env ~incoming:incoming_taints in
  let source_pms = lval_is_source env lval in
  (* Partition sources according to the value of `by-side-effect:`,
   * either `only`, `yes`, or `no`. *)
  let ( `Only by_side_effect_only_pms,
        `Yes by_side_effect_yes_pms,
        `No by_side_effect_no_pms ) =
    partition_sources_by_side_effect source_pms
  in
  let by_side_effect_only_taints, lval_env =
    by_side_effect_only_pms
    (* We require an exact match for `by-side-effect` to take effect. *)
    |> List.filter TM.is_exact
    |> taints_of_pms env
  in
  let by_side_effect_yes_taints, lval_env =
    by_side_effect_yes_pms
    (* We require an exact match for `by-side-effect` to take effect. *)
    |> List.filter TM.is_exact
    |> taints_of_pms { env with lval_env }
  in
  let by_side_effect_no_taints, lval_env =
    by_side_effect_no_pms |> taints_of_pms { env with lval_env }
  in
  let taints_to_add_to_env =
    by_side_effect_only_taints |> Taints.union by_side_effect_yes_taints
  in
  let lval_env = lval_env |> Lval_env.add lval taints_to_add_to_env in
  let taints_to_return =
    Taints.union by_side_effect_no_taints by_side_effect_yes_taints
  in
  (taints_to_return, lval_env)

let rec check_tainted_lval env (lval : IL.lval) :
    Taints.t * S.shape * [ `Sub of Taints.t * S.shape ] * Lval_env.t =
  let new_taints, lval_in_env, lval_shape, sub, lval_env =
    check_tainted_lval_aux env lval
  in
  let taints_from_env = Xtaint.to_taints lval_in_env in
  let taints = Taints.union new_taints taints_from_env in
  let taints =
    check_type_and_drop_taints_if_bool_or_number env taints type_of_lval lval
  in
  let sinks =
    lval_is_sink env lval
    |> List.filter (TM.is_best_match env.best_matches)
    |> List_.map TM.sink_of_match
  in
  let results = results_of_tainted_sinks { env with lval_env } taints sinks in
  report_results { env with lval_env } results;
  (taints, lval_shape, sub, lval_env)

(* Java: Whenever we find a getter/setter without definition we end up here,
 * this happens if the getter/setters are being autogenerated at build time,
 * as when you use Lombok. This function will "resolve" the getter/setter to
 * the corresponding property, and propagate taint to/from that property.
 * So that `o.getX()` returns whatever taints `o.x` has, and so `o.setX(E)`
 * propagates any taints in `E` to `o.x`. *)
and propagate_taint_via_java_getters_and_setters_without_definition env e args
    all_args_taints =
  match e with
  | {
   e =
     Fetch
       ({
          base = Var obj;
          rev_offset =
            [ { o = Dot { IL.ident = method_str, method_tok; sid; _ }; _ } ];
        } as lval);
   _;
  }
  (* We check for the "get"/"set" prefix below. *)
    when env.lang =*= Lang.Java && String.length method_str > 3 -> (
      let mk_prop_lval () =
        (* e.g. getFooBar/setFooBar -> fooBar *)
        let prop_str =
          String.uncapitalize_ascii (Str.string_after method_str 3)
        in
        let prop_name =
          (* FIXME: Pro should be autogenerating definitions for these getters/setters,
           * but that seems to hurt performance and it's still unclear why, so instead
           * we give taint access to Pro typing info via 'hook_find_attribute_in_class'
           * and look for the property corresponding to the getter/setter.
           *
           * On very large files, allocating a new name every time can have a perf impact,
           * so we cache them. *)
          match Hashtbl.find_opt env.java_props (prop_str, sid) with
          | Some prop_name -> prop_name
          | None -> (
              let mk_default_prop_name () =
                let prop_name =
                  {
                    ident = (prop_str, method_tok);
                    sid = G.SId.unsafe_default;
                    id_info = G.empty_id_info ();
                  }
                in
                Hashtbl.add env.java_props (prop_str, sid) prop_name;
                prop_name
              in
              match (!(obj.id_info.id_type), !hook_find_attribute_in_class) with
              | Some { t = TyN class_name; _ }, Some hook -> (
                  match hook class_name prop_str with
                  | None -> mk_default_prop_name ()
                  | Some prop_name ->
                      let prop_name = AST_to_IL.var_of_name prop_name in
                      Hashtbl.add env.java_props (prop_str, sid) prop_name;
                      prop_name)
              | __else__ -> mk_default_prop_name ())
        in
        { lval with rev_offset = [ { o = Dot prop_name; oorig = NoOrig } ] }
      in
      match args with
      | [] when String.(starts_with ~prefix:"get" method_str) ->
          let taints, shape, _sub, lval_env =
            check_tainted_lval env (mk_prop_lval ())
          in
          Some (taints, shape, lval_env)
      | [ _ ] when String.starts_with ~prefix:"set" method_str ->
          if not (Taints.is_empty all_args_taints) then
            Some
              ( Taints.empty,
                S.Bot,
                env.lval_env |> Lval_env.add (mk_prop_lval ()) all_args_taints
              )
          else Some (Taints.empty, S.Bot, env.lval_env)
      | __else__ -> None)
  | __else__ -> None

and check_tainted_lval_aux env (lval : IL.lval) :
    Taints.t
    * Xtaint.t_or_sanitized
    * S.shape
    * [ `Sub of Taints.t * S.shape ]
    * Lval_env.t =
  (* Recursively checks an l-value bottom-up.
   *
   *  This check needs to combine matches from pattern-{sources,sanitizers,sinks}
   *  with the info we have stored in `env.lval_env`. This can be subtle, see
   *  comments below.
   *)
  match lval_is_best_sanitizer env lval with
  (* See NOTE [is_sanitizer] *)
  (* TODO: We should check that taint and sanitizer(s) are unifiable. *)
  | _ :: _ as sanitizer_pms ->
      (* NOTE [lval/sanitized]:
       *  If lval is sanitized, then we will "bubble up" the `Sanitized status, so
       *  any taint recorded in lval_env for any extension of lval will be discarded.
       *
       *  So, if we are checking `x.a.b.c` and `x.a` is sanitized then any extension
       *  of `x.a` is considered sanitized as well, and we do look for taint info in
       *  the environment.
       *
       *  *IF* sanitization is side-effectful then any taint info will be removed
       *  from lval_env by sanitize_lval, but that is not guaranteed.
       *)
      let lval_env =
        sanitize_lval_by_side_effect env.lval_env sanitizer_pms lval
      in
      (Taints.empty, `Sanitized, S.Bot, `Sub (Taints.empty, S.Bot), lval_env)
  | [] ->
      (* Recursive call, check sub-lvalues first.
       *
       * It needs to be done bottom-up because any sub-lvalue can be a source and a
       * sink by itself, even if an extension of lval is not. For example, given
       * `x.a.b`, this lvalue may be considered sanitized, but at the same time `x.a`
       * could be tainted and considered a sink in some context. We cannot just check
       * `x.a.b` and forget about the sub-lvalues.
       *)
      let sub_new_taints, sub_in_env, sub_shape, lval_env =
        match lval with
        | { base; rev_offset = [] } ->
            (* Base case, no offset. *)
            check_tainted_lval_base env base
        | { base = _; rev_offset = _ :: rev_offset' } ->
            (* Recursive case, given `x.a.b` we must first check `x.a`. *)
            let sub_new_taints, sub_in_env, sub_shape, _sub_sub, lval_env =
              check_tainted_lval_aux env { lval with rev_offset = rev_offset' }
            in
            (sub_new_taints, sub_in_env, sub_shape, lval_env)
      in
      let sub_new_taints, sub_in_env =
        if env.options.taint_only_propagate_through_assignments then
          match sub_in_env with
          | `Sanitized -> (Taints.empty, `Sanitized)
          | `Clean
          | `None
          | `Tainted _ ->
              (Taints.empty, `None)
        else (sub_new_taints, sub_in_env)
      in
      (* Check the status of lval in the environemnt. *)
      let lval_in_env, lval_shape =
        match sub_in_env with
        | `Sanitized ->
            (* See NOTE [lval/sanitized] *)
            (`Sanitized, S.Bot)
        | (`Clean | `None | `Tainted _) as sub_xtaint ->
            let xtaint', shape =
              (* THINK: Should we just use 'S.find_in_shape' directly here ?
                       We have the 'sub_shape' available. *)
              match Lval_env.find_lval lval_env lval with
              | None -> (`None, S.Bot)
              | Some (Ref (xtaint', shape)) -> (xtaint', shape)
            in
            let xtaint' =
              match xtaint' with
              | (`Clean | `Tainted _) as xtaint' -> xtaint'
              | `None ->
                  (* HACK(field-sensitivity): If we encounter `obj.x` and `obj` has
                     * polymorphic taint, and we know nothing specific about `obj.x`, then
                     * we add the same offset `.x` to the polymorphic taint coming from `obj`.
                     * (See also 'propagate_taint_via_unresolved_java_getters_and_setters'.)
                     *
                     * For example, given `function foo(o) { sink(o.x); }`, and being '0 the
                     * polymorphic taint of `o`, this allows us to record that what goes into
                     * the sink is '0.x (and not just '0). So if later we encounter `foo(obj)`
                     * where `obj.y` is tainted but `obj.x` is not tainted, we will not
                     * produce a finding.
                  *)
                  fix_poly_taint_with_field env lval sub_xtaint
            in
            (xtaint', shape)
      in
      let taints_from_env = Xtaint.to_taints lval_in_env in
      (* Find taint sources matching lval. *)
      let current_taints = Taints.union sub_new_taints taints_from_env in
      let taints_from_sources, lval_env =
        find_lval_taint_sources { env with lval_env } current_taints lval
      in
      (* Check sub-expressions in the offset. *)
      let taints_from_offset, lval_env =
        match lval.rev_offset with
        | [] -> (Taints.empty, lval_env)
        | offset :: _ -> check_tainted_lval_offset { env with lval_env } offset
      in
      (* Check taint propagators. *)
      let taints_incoming (* TODO: find a better name *) =
        if env.options.taint_only_propagate_through_assignments then
          taints_from_sources
        else
          sub_new_taints
          |> Taints.union taints_from_sources
          |> Taints.union taints_from_offset
      in
      let taints_propagated, lval_env =
        handle_taint_propagators { env with lval_env } (`Lval lval)
          (taints_incoming |> Taints.union taints_from_env)
          lval_shape
      in
      let new_taints = taints_incoming |> Taints.union taints_propagated in
      let sinks =
        lval_is_sink env lval
        (* For sub-lvals we require sinks to be exact matches. Why? Let's say
           * we have `sink(x.a)` and `x' is tainted but `x.a` is clean...
           * with the normal subset semantics for sinks we would consider `x'
           * itself to be a sink, and we would report a finding!
        *)
        |> List.filter TM.is_exact
        |> List_.map TM.sink_of_match
      in
      let all_taints = Taints.union taints_from_env new_taints in
      let results =
        results_of_tainted_sinks { env with lval_env } all_taints sinks
      in
      report_results { env with lval_env } results;
      ( new_taints,
        lval_in_env,
        lval_shape,
        `Sub (Xtaint.to_taints sub_in_env, sub_shape),
        lval_env )

and check_tainted_lval_base env base =
  match base with
  | Var _
  | VarSpecial _ ->
      (Taints.empty, `None, S.Bot, env.lval_env)
  | Mem { e = Fetch lval; _ } ->
      (* i.e. `*ptr` *)
      let taints, lval_in_env, shape, _sub, lval_env =
        check_tainted_lval_aux env lval
      in
      (taints, lval_in_env, shape, lval_env)
  | Mem e ->
      let taints, shape, lval_env = check_tainted_expr env e in
      (taints, `None, shape, lval_env)

and check_tainted_lval_offset env offset =
  match offset.o with
  | Dot _n ->
      (* THINK: Allow fields to be taint sources, sanitizers, or sinks ??? *)
      (Taints.empty, env.lval_env)
  | Index e ->
      let taints, _shape, lval_env = check_tainted_expr env e in
      let taints =
        if propagate_through_indexes env then taints
        else (* Taints from the index should be ignored. *)
          Taints.empty
      in
      (taints, lval_env)

(* Test whether an expression is tainted, and if it is also a sink,
 * report the finding too (by side effect). *)
and check_tainted_expr env exp : Taints.t * S.shape * Lval_env.t =
  let check env = check_tainted_expr env in
  let check_subexpr exp =
    match exp.e with
    | Fetch _
    (* TODO: 'Fetch' is handled specially, this case should not never be taken.  *)
    | Literal _
    | FixmeExp (_, _, None) ->
        (Taints.empty, S.Bot, env.lval_env)
    | FixmeExp (_, _, Some e) ->
        let taints, shape, lval_env = check env e in
        let taints =
          taints |> Taints.union (S.gather_all_taints_in_shape shape)
        in
        (taints, S.Bot, lval_env)
    | Composite ((CTuple | CArray | CList), (_, es, _)) ->
        let taints_and_shapes, lval_env = map_check_expr env check es in
        let obj = S.tuple_like_obj taints_and_shapes in
        (Taints.empty, Obj obj, lval_env)
    | Composite ((CSet | Constructor _ | Regexp), (_, es, _)) ->
        let taints, lval_env = union_map_taints_and_vars env check es in
        (taints, S.Bot, lval_env)
    | Operator ((op, _), es) ->
        let args_taints, all_args_taints, lval_env =
          check_function_call_arguments env es
        in
        let all_args_taints =
          all_args_taints
          |> Taints.union (gather_all_taints_in_args_taints args_taints)
        in
        let all_args_taints =
          if env.options.taint_only_propagate_through_assignments then
            Taints.empty
          else all_args_taints
        in
        let op_taints =
          match op with
          | G.Eq
          | G.NotEq
          | G.PhysEq
          | G.NotPhysEq
          | G.Lt
          | G.LtE
          | G.Gt
          | G.GtE
          | G.Cmp
          | G.RegexpMatch
          | G.NotMatch
          | G.In
          | G.NotIn
          | G.Is
          | G.NotIs ->
              if env.options.taint_assume_safe_comparisons then Taints.empty
              else all_args_taints
          | G.And
          | G.Or
          | G.Xor
          | G.Not
          | G.LSL
          | G.LSR
          | G.ASR
          | G.BitOr
          | G.BitXor
          | G.BitAnd
          | G.BitNot
          | G.BitClear
          | G.Plus
          | G.Minus
          | G.Mult
          | G.Div
          | G.Mod
          | G.Pow
          | G.FloorDiv
          | G.MatMult
          | G.Concat
          | G.Append
          | G.Range
          | G.RangeInclusive
          | G.NotNullPostfix
          | G.Length
          | G.Elvis
          | G.Nullish
          | G.Background
          | G.Pipe ->
              all_args_taints
        in
        (op_taints, S.Bot, lval_env)
    | RecordOrDict fields ->
        (* TODO: Construct a proper record/dict shape here. *)
        let fields_exprs =
          fields
          |> List.concat_map (function
               | Field (_, e)
               | Spread e ->
                   [ e ]
               | Entry (ke, ve) -> [ ke; ve ])
        in
        let taints, lval_env =
          union_map_taints_and_vars env check fields_exprs
        in
        (taints, S.Bot, lval_env)
    | Cast (_, e) -> check env e
  in
  match exp_is_sanitized env exp with
  (* THINK: Can we just skip checking the subexprs in 'exp'? There could be a
   * sanitizer by-side-effect that will not trigger, see CODE-6548. E.g.
   * if `x` in `foo(x)` is supposed to be sanitized by-side-effect, but `foo(x)`
   * itself is sanitized, the by-side-effect sanitization of `x` will not happen.
   * Problem is, we do not want sources or propagators by-side-effect to trigger
   * on `x` if `foo(x)` is sanitized, so we would need to check the subexprs while
   * disabling taint sources.
   *)
  | Some lval_env ->
      (* TODO: We should check that taint and sanitizer(s) are unifiable. *)
      (Taints.empty, S.Bot, lval_env)
  | None ->
      let taints, shape, lval_env =
        match exp.e with
        | Fetch lval ->
            let taints, shape, _sub, lval_env = check_tainted_lval env lval in
            (taints, shape, lval_env)
        | __else__ ->
            let taints_exp, shape, lval_env = check_subexpr exp in
            let taints_sources, lval_env =
              orig_is_best_source env exp.eorig
              |> taints_of_matches { env with lval_env } ~incoming:taints_exp
            in
            let taints = taints_exp |> Taints.union taints_sources in
            let taints_propagated, lval_env =
              handle_taint_propagators { env with lval_env } (`Exp exp) taints
                shape
            in
            let taints = Taints.union taints taints_propagated in
            (taints, shape, lval_env)
      in
      check_orig_if_sink env exp.eorig taints shape;
      (taints, shape, lval_env)

(* Check the actual arguments of a function call. This also handles left-to-right
 * taint propagation by chaining the 'lval_env's returned when checking the arguments.
 * For example, given `foo(x.a)` we'll check whether `x.a` is tainted or whether the
 * argument is a sink. *)
and check_function_call_arguments env args =
  let (rev_taints, lval_env), args_taints =
    args
    |> List.fold_left_map
         (fun (rev_taints, lval_env) arg ->
           let e = IL_helpers.exp_of_arg arg in
           let taints, shape, lval_env =
             check_tainted_expr { env with lval_env } e
           in
           let taints =
             check_type_and_drop_taints_if_bool_or_number env taints
               type_of_expr e
           in
           let new_acc = (taints :: rev_taints, lval_env) in
           match arg with
           | Unnamed _ -> (new_acc, Unnamed (taints, shape))
           | Named (id, _) -> (new_acc, Named (id, (taints, shape))))
         ([], env.lval_env)
  in
  let all_args_taints = List.fold_left Taints.union Taints.empty rev_taints in
  (args_taints, all_args_taints, lval_env)

let check_tainted_var env (var : IL.name) : Taints.t * S.shape * Lval_env.t =
  let taints, shape, _sub, lval_env =
    check_tainted_lval env (LV.lval_of_var var)
  in
  (taints, shape, lval_env)

(* Given a function/method call 'fun_exp'('args_exps'), and an argument
 * spec 'sig_lval' from the taint signature of the called function/method,
 * determine what lvalue corresponds to 'sig_lval'.
 *
 * In the simplest case this just obtains the actual argument:
 * E.g. `lval_of_sig_lval f [x;y;z] [a;b;c] (x,0) = a`
 *
 * The 'sig_lval' may refer to `this` and also have an offset:
 * E.g. `lval_of_sig_lval o.f [] [] (this,-1).x = o.x`
 *)
let lval_of_sig_lval fun_exp fparams args_exps (sig_lval : T.lval) :
    (* Besides the 'lval', we also return a "tainted token" pointing to an
     * identifier in the actual code that relates to 'sig_lval', to be used
     * in the taint trace.  For example, if we're calling `obj.method` and
     * `this.x` were tainted, then we would record that taint went through
     * `obj`. *)
    (lval * T.tainted_token) option =
  let* rev_offset = T.rev_IL_offset_of_offset sig_lval.offset in
  let* lval, obj =
    match sig_lval.base with
    | BGlob gvar -> Some ({ base = Var gvar; rev_offset }, gvar)
    | BThis -> (
        match fun_exp with
        | {
         e = Fetch { base = Var obj; rev_offset = [ { o = Dot _method; _ } ] };
         _;
        } ->
            (* We're calling `obj.method`, so `this.x` is actually `obj.x` *)
            Some ({ base = Var obj; rev_offset }, obj)
        | { e = Fetch { base = Var method_; rev_offset = [] }; _ } ->
            (* We're calling a `method` on the same instace of the caller,
             * and `this.x` is just `this.x` *)
            let this =
              VarSpecial (This, Tok.fake_tok (snd method_.ident) "this")
            in
            Some ({ base = this; rev_offset }, method_)
        | __else__ -> None)
    | BArg pos -> (
        let* arg_exp = find_pos_in_actual_args args_exps fparams pos in
        match (arg_exp.e, sig_lval.offset) with
        | Fetch ({ base = Var obj; _ } as arg_lval), _ ->
            let lval =
              { arg_lval with rev_offset = rev_offset @ arg_lval.rev_offset }
            in
            Some (lval, obj)
        | RecordOrDict fields, [ Ofld o ] -> (
            (* JS: The argument of a function call may be a record expression such as
             * `{x="tainted", y="safe"}`, if 'sig_lval' refers to the `x` field then
             * we want to resolve it to `"tainted"`. *)
            match
              fields
              |> List.find_opt (function
                   (* The 'o' is the offset that 'sig_lval' is referring to, here
                    * we look for a `fld=lval` field in the record object such that
                    * 'fld' has the same name as 'o'. *)
                   | Field (fld, _) -> fst fld = fst o.ident
                   | Entry _
                   | Spread _ ->
                       false)
            with
            | Some (Field (_, { e = Fetch ({ base = Var obj; _ } as lval); _ }))
              ->
                (* Actual argument is of the form {..., fld=lval, ...} and the offset is 'fld',
                 * we return 'lval'. *)
                Some (lval, obj)
            | Some _
            | None ->
                None)
        | __else__ -> None)
  in
  Some (lval, snd obj.ident)

(* HACK(implicit-taint-variables-in-env):
 * We have a function call with a taint variable, corresponding to a global or
 * a field in the same class as the caller, that  reaches a sink. However, in
 * the caller we have no taint for the corresponding l-value.
 *
 * Why?
 * In 'find_instance_and_global_variables_in_fdef' we only add  to the input-env
 * those globals and fields that occur in the  definition of a method, but just
 * because a global/field is  not in there, it does not mean it's not in scope!
 *
 * What to do?
 * We can just propagate the very same taint variable, assuming that it is
 * implicitly in scope.
 *
 * Example (see SAF-1059):
 *
 *     string bad;
 *
 *     void test() {
 *         bad = "taint";
 *         // Thanks to this HACK we will know that calling 'foo'
 *         // here makes "taint" go into a sink.
 *         foo();
 *     }
 *
 *     void foo() {
 *         // We instantiate `bar` and we see 'bad ~~~> sink',
 *         // but `bad` is not in the environment, however we
 *         // know `bad` is a field in the same class as `foo`,
 *         // so we propagate it as-is.
 *         bar();
 *     }
 *
 *     // signature: bad ~~~> sink
 *     void bar() {
 *         sink(bad);
 *     }
 *
 * ALTERNATIVE:
 * In 'Deep_tainting.infer_taint_sigs_of_fdef', when we build
 * the taint input-env, we could collect all the globals and
 * class fields in scope, regardless of whether they occur or
 * not in the method definition. Main concern here is whether
 * input environments could end up being too big.
 *)
let fix_lval_taints_if_global_or_a_field_of_this_class fun_exp (lval : T.lval)
    lval_taints =
  let is_method_in_this_class =
    match fun_exp with
    | { e = Fetch { base = Var _method; rev_offset = [] }; _ } ->
        (* We're calling a `method` on the same instace of the caller,
           so `this.x` in the taint signature of the callee corresponds to
           `this.x` in the caller. *)
        true
    | __else__ -> false
  in
  match lval.base with
  | BArg _ -> lval_taints
  | BThis when not is_method_in_this_class -> lval_taints
  | BGlob _
  | BThis
    when not (Taints.is_empty lval_taints) ->
      lval_taints
  | BGlob _
  | BThis ->
      (* 'lval' is either a global variable or a field in the same class
       * as the caller of 'fun_exp', and no taints are found for 'lval':
       * we assume 'lval' is implicitly in the input-environment and
       * return it as a type variable. *)
      Taints.singleton { orig = Var lval; tokens = [] }

(* What is the taint denoted by 'sig_lval' ? *)
let taints_of_sig_lval env fparams fun_exp args_exps args_taints
    (sig_lval : T.lval) =
  match sig_lval with
  | { base = BArg pos; offset = [] } ->
      find_pos_in_actual_args args_taints fparams pos
  | __else__ ->
      (* We want to know what's the taint carried by 'arg_exp.x1. ... .xN'. *)
      let* lval, _obj = lval_of_sig_lval fun_exp fparams args_exps sig_lval in
      let lval_taints, shape, _sub, _lval_env = check_tainted_lval env lval in
      let lval_taints =
        lval_taints
        |> fix_lval_taints_if_global_or_a_field_of_this_class fun_exp sig_lval
      in
      Some (lval_taints, shape)

(* This function is consuming the taint signature of a function to determine
   a few things:
   1) What is the status of taint in the current environment, after the function
      call occurs?
   2) Are there any results that occur within the function due to taints being
      input into the function body, from the calling context?
*)
let check_function_signature env fun_exp args args_taints =
  match (!hook_function_taint_signature, fun_exp) with
  | Some hook, { e = Fetch f; eorig = SameAs eorig } ->
      let* fparams, fun_sig = hook env.config eorig in
      Logs.debug (fun m ->
          m ~tags:sigs "Call to %s : %s" (_show_fun_exp fun_exp)
            (Sig.show_signature fun_sig));
      (* This function simply produces the corresponding taints to the
          given argument, within the body of the function.
      *)
      (* Our first pass will be to substitute the args for taints.
         We can't do this indiscriminately at the beginning, because
         we might need to use some of the information of the pre-substitution
         taints and the post-substitution taints, for instance the tokens.

         So we will isolate this as a specific step to be applied as necessary.
      *)
      let lval_to_taints lval =
        taints_of_sig_lval env fparams fun_exp args args_taints lval
      in
      (* TODO: We should instantiate the entire taint signature at once,
       *       rather than having subtitution scattered as we have here.
       *       This could be 'Taint_sig'. We could take the 'taints_of_lval'
       *       function as a parameter. *)
      let subst_in_precondition taint =
        let subst taints =
          taints
          |> List.concat_map (fun t ->
                 match t.T.orig with
                 | Src _ -> [ t ]
                 | Var lval ->
                     let+ var_taints, var_shape = lval_to_taints lval in
                     (* Taint here is only used to resolve preconditions for taint
                      * variables affected by labels. Seems right to gather all the
                      * taints from the shape too. *)
                     let var_taints =
                       var_taints
                       |> Taints.union (S.gather_all_taints_in_shape var_shape)
                     in
                     Taints.elements var_taints
                 | Control ->
                     Lval_env.get_control_taints env.lval_env |> Taints.elements)
        in
        T.map_preconditions subst taint
      in
      let process_sig :
          Sig.result ->
          [ `Return of Taints.t
          | (* ^ Taints flowing through the function's output *)
            `UpdateEnv of
            lval * Taints.t
            (* ^ Taints flowing through function's arguments (or the callee object) by side-effect *)
          ]
          list = function
        | Sig.ToReturn (taints, _return_tok) ->
            taints
            |> List_.map_filter (fun t ->
                   match t.T.orig with
                   | Src src ->
                       let call_trace =
                         T.Call (eorig, t.tokens, src.call_trace)
                       in
                       let* taint =
                         {
                           Taint.orig = Src { src with call_trace };
                           tokens = [];
                         }
                         |> subst_in_precondition
                       in
                       Some (`Return (Taints.singleton taint))
                   | Var lval ->
                       let* lval_taints, lval_shape = lval_to_taints lval in
                       let lval_taints =
                         lval_taints
                         |> Taints.union
                              (S.gather_all_taints_in_shape lval_shape)
                       in
                       (* Get the token of the function *)
                       let* ident =
                         match f with
                         (* Case `$F()` *)
                         | { base = Var { ident; _ }; rev_offset = []; _ }
                         (* Case `$X. ... .$F()` *)
                         | {
                             base = _;
                             rev_offset = { o = Dot { ident; _ }; _ } :: _;
                             _;
                           } ->
                             Some ident
                         | __else__ -> None
                       in
                       Some
                         (`Return
                           (lval_taints
                           |> Taints.map (fun taint ->
                                  let tokens =
                                    t.tokens @ (snd ident :: taint.tokens)
                                  in
                                  { taint with tokens })))
                   | Control ->
                       (* Control taint does not need to propagate via `return`s. *)
                       None)
        | Sig.ToSink { taints_with_precondition = taints, _requires; sink; _ }
          ->
            let incoming_taints =
              taints
              |> List.concat_map (fun { Sig.taint; sink_trace } ->
                     match taint.T.orig with
                     | T.Src _ ->
                         (* Here, we do not modify the call trace or the taint.
                            This is because this means that, without our intervention, a
                            source of taint reaches the sink upon invocation of this function.
                            As such, we don't need to touch its call trace.
                         *)
                         (* Additionally, we keep this taint around, as compared to before,
                            when we assumed that only a single taint was necessary to produce
                            a finding.
                            Before, we assumed we could get rid of it because a
                            previous `results_of_tainted_sink` call would have already
                            reported on this source. However, with interprocedural taint labels,
                            a finding may now be dependent on multiple such taints. If we were
                            to get rid of this source taint now, we might fail to report a
                            finding from a function call, because we failed to store the information
                            of this source taint within that function's taint signature.

                            e.g.

                            def bar(y):
                              foo(y)

                            def foo(x):
                              a = source_a
                              sink_of_a_and_b(a, x)

                            Here, we need to keep the source taint around, or our `bar` function
                            taint signature will fail to realize that the taint of `source_a` is
                            going into `sink_of_a_and_b`, and we will fail to produce a finding.
                         *)
                         let+ taint = taint |> subst_in_precondition in
                         [ { Sig.taint; sink_trace } ]
                     | Var lval ->
                         let sink_trace =
                           T.Call (eorig, taint.tokens, sink_trace)
                         in
                         let+ lval_taints, lval_shape = lval_to_taints lval in
                         (* See NOTE(gather-all-taints) *)
                         let lval_taints =
                           lval_taints
                           |> Taints.union
                                (S.gather_all_taints_in_shape lval_shape)
                         in
                         Taints.elements lval_taints
                         |> List_.map (fun x -> { Sig.taint = x; sink_trace })
                     | Control ->
                         (* coupling: how to best refactor with Arg's case? *)
                         let sink_trace =
                           T.Call (eorig, taint.tokens, sink_trace)
                         in
                         let control_taints =
                           Lval_env.get_control_taints env.lval_env
                         in
                         Taints.elements control_taints
                         |> List_.map (fun x -> { Sig.taint = x; sink_trace }))
            in
            results_of_tainted_sink env incoming_taints sink
            |> report_results env;
            []
        | Sig.ToLval (taints, dst_sig_lval) ->
            (* Taints 'taints' go into an argument of the call, by side-effect.
             * Right now this is mainly used to track taint going into specific
             * fields of the callee object, like `this.x = "tainted"`. *)
            let+ dst_lval, tainted_tok =
              (* 'dst_lval' is the actual argument/l-value that corresponds
                 * to the formal argument 'dst_sig_lval'. *)
              lval_of_sig_lval fun_exp fparams args dst_sig_lval
            in
            taints
            |> List.concat_map (fun t ->
                   let dst_taints =
                     match t.T.orig with
                     | Src src -> (
                         let call_trace =
                           T.Call (eorig, t.tokens, src.call_trace)
                         in
                         let t =
                           {
                             Taint.orig = Src { src with call_trace };
                             tokens = [];
                           }
                         in
                         match t |> subst_in_precondition with
                         | None -> Taints.empty
                         | Some t -> Taints.singleton t)
                     | Var src_lval ->
                         (* Taint is flowing from one argument to another argument
                          * (or possibly the callee object). Given the formal poly
                          * taint 'src_lval', we compute the actual taint in the
                          * context of this function call. *)
                         let& res, _TODOshape = lval_to_taints src_lval in
                         res
                         |> Taints.map (fun taint ->
                                let tokens =
                                  t.tokens @ (tainted_tok :: taint.T.tokens)
                                in
                                { taint with tokens })
                     | Control ->
                         (* control taints do not propagate to arguments *)
                         Taints.empty
                   in
                   if Taints.is_empty dst_taints then []
                   else [ `UpdateEnv (dst_lval, dst_taints) ])
      in
      Some
        (fun_sig |> Sig.Results.elements
        |> List.concat_map process_sig
        |> List.fold_left
             (fun (taints_acc, lval_env) fsig ->
               match fsig with
               | `Return taints -> (Taints.union taints taints_acc, lval_env)
               | `UpdateEnv (lval, taints) ->
                   (taints_acc, lval_env |> Lval_env.add lval taints))
             (Taints.empty, env.lval_env))
  | None, _
  | Some _, _ ->
      None

let check_function_call_callee env e =
  match e.e with
  | Fetch ({ base = _; rev_offset = _ :: _ } as lval) ->
      (* Method call <object ...>.<method>, the 'sub_taints' and 'sub_shape'
       * correspond to <object ...>. *)
      let taints, shape, `Sub (sub_taints, sub_shape), lval_env =
        check_tainted_lval env lval
      in
      let obj_taints =
        sub_taints |> Taints.union (S.gather_all_taints_in_shape sub_shape)
      in
      (`Obj obj_taints, taints, shape, lval_env)
  | __else__ ->
      let taints, shape, lval_env = check_tainted_expr env e in
      (`Fun, taints, shape, lval_env)

(* Test whether an instruction is tainted, and if it is also a sink,
 * report the result too (by side effect). *)
let check_tainted_instr env instr : Taints.t * S.shape * Lval_env.t =
  let check_expr env = check_tainted_expr env in
  let check_instr = function
    | Assign (_, e) ->
        let taints, shape, lval_env = check_expr env e in
        let taints =
          check_type_and_drop_taints_if_bool_or_number env taints type_of_expr e
        in
        (taints, shape, lval_env)
    | AssignAnon _ -> (Taints.empty, S.Bot, env.lval_env)
    | Call (_, e, args) ->
        let args_taints, all_args_taints, lval_env =
          check_function_call_arguments env args
        in
        let all_args_taints =
          all_args_taints
          |> Taints.union (gather_all_taints_in_args_taints args_taints)
        in
        let e_obj, e_taints, _e_shape, lval_env =
          check_function_call_callee { env with lval_env } e
        in
        (* NOTE(sink_has_focus):
         * After we made sink specs "exact" by default, we need this trick to
         * be backwards compatible wrt to specifications like `sink(...)`. Even
         * if the sink is "exact", if it has NO focus, then we consider that all
         * of the parameters of the function are sinks. So, even if
         * `taint_assume_safe_functions: true`, if the spec is `sink(...)`, we
         * still report `sink(tainted)`.
         *)
        check_orig_if_sink { env with lval_env } instr.iorig all_args_taints
          S.Bot ~filter_sinks:(fun m ->
            not (m.spec.sink_exact && m.spec.sink_has_focus));
        let call_taints, shape, lval_env =
          match
            check_function_signature { env with lval_env } e args args_taints
          with
          | Some (call_taints, lval_env) -> (call_taints, S.Bot, lval_env)
          | None -> (
              let call_taints =
                if not (propagate_through_functions env) then Taints.empty
                else
                  (* Otherwise assume that the function will propagate
                     * the taint of its arguments. *)
                  all_args_taints
              in
              match
                propagate_taint_via_java_getters_and_setters_without_definition
                  { env with lval_env } e args all_args_taints
              with
              | Some (getter_taints, _TODOshape, lval_env) ->
                  (* HACK: Java: If we encounter `obj.setX(arg)` we interpret it as
                   * `obj.x = arg`, if we encounter `obj.getX()` we interpret it as
                   * `obj.x`. *)
                  let call_taints = Taints.union call_taints getter_taints in
                  (call_taints, S.Bot, lval_env)
              | None ->
                  (* We have no taint signature and it's neither a get/set method. *)
                  if not (propagate_through_functions env) then
                    (Taints.empty, S.Bot, lval_env)
                  else
                    (* If this is a method call, `o.method(...)`, then we fetch the
                       * taint of the callee object `o`. This is a conservative worst-case
                       * asumption that any taint in `o` can be tainting the call's result. *)
                    let call_taints =
                      match e_obj with
                      | `Fun -> call_taints
                      | `Obj obj_taints ->
                          call_taints |> Taints.union obj_taints
                    in
                    (call_taints, S.Bot, lval_env))
        in
        (* We add the taint of the function itselt (i.e., 'e_taints') too. *)
        let all_call_taints =
          if env.options.taint_only_propagate_through_assignments then
            call_taints
          else Taints.union e_taints call_taints
        in
        let all_call_taints =
          check_type_and_drop_taints_if_bool_or_number env all_call_taints
            type_of_expr e
        in
        (all_call_taints, shape, lval_env)
    | New (_lval, _ty, Some constructor, args) -> (
        (* 'New' with reference to constructor, although it doesn't mean it has been resolved. *)
        let args_taints, all_args_taints, lval_env =
          check_function_call_arguments env args
        in
        match
          check_function_signature { env with lval_env } constructor args
            args_taints
        with
        | Some (call_taints, lval_env) ->
            (* TODO: 'new' should return the shape of the object being constructed *)
            (call_taints, S.Bot, lval_env)
        | None ->
            let all_args_taints =
              all_args_taints
              |> Taints.union (gather_all_taints_in_args_taints args_taints)
            in
            let all_args_taints =
              if env.options.taint_only_propagate_through_assignments then
                Taints.empty
              else all_args_taints
            in
            (all_args_taints, S.Bot, lval_env))
    | New (_lval, _ty, None, args) ->
        (* 'New' without reference to constructor *)
        let args_taints, all_args_taints, lval_env =
          check_function_call_arguments env args
        in
        let all_args_taints =
          all_args_taints
          |> Taints.union (gather_all_taints_in_args_taints args_taints)
        in
        let all_args_taints =
          if env.options.taint_only_propagate_through_assignments then
            Taints.empty
          else all_args_taints
        in
        (all_args_taints, S.Bot, lval_env)
    | CallSpecial (_, _, args) ->
        let args_taints, all_args_taints, lval_env =
          check_function_call_arguments env args
        in
        let all_args_taints =
          all_args_taints
          |> Taints.union (gather_all_taints_in_args_taints args_taints)
        in
        let all_args_taints =
          if env.options.taint_only_propagate_through_assignments then
            Taints.empty
          else all_args_taints
        in
        (all_args_taints, S.Bot, lval_env)
    | FixmeInstr _ -> (Taints.empty, S.Bot, env.lval_env)
  in
  let sanitizer_pms = orig_is_best_sanitizer env instr.iorig in
  match sanitizer_pms with
  (* See NOTE [is_sanitizer] *)
  | _ :: _ ->
      (* TODO: We should check that taint and sanitizer(s) are unifiable. *)
      (Taints.empty, S.Bot, env.lval_env)
  | [] ->
      let taints_instr, rhs_shape, lval_env = check_instr instr.i in
      let taint_sources, lval_env =
        orig_is_best_source env instr.iorig
        |> taints_of_matches { env with lval_env } ~incoming:taints_instr
      in
      let taints = Taints.union taints_instr taint_sources in
      let taints_propagated, lval_env =
        handle_taint_propagators { env with lval_env } (`Ins instr) taints
          rhs_shape
      in
      let taints = Taints.union taints taints_propagated in
      check_orig_if_sink env instr.iorig taints rhs_shape;
      let taints =
        match LV.lval_of_instr_opt instr with
        | None -> taints
        | Some lval ->
            check_type_and_drop_taints_if_bool_or_number env taints type_of_lval
              lval
      in
      (taints, rhs_shape, lval_env)

(* Test whether a `return' is tainted, and if it is also a sink,
 * report the result too (by side effect). *)
let check_tainted_return env tok e : Taints.t * S.shape * Lval_env.t =
  let sinks =
    any_is_best_sink env (G.Tk tok) @ orig_is_best_sink env e.eorig
    |> List.filter (TM.is_best_match env.best_matches)
    |> List_.map TM.sink_of_match
  in
  let taints, shape, var_env' = check_tainted_expr env e in
  let taints =
    (* TODO: Clean shape as well based on type ? *)
    check_type_and_drop_taints_if_bool_or_number env taints type_of_expr e
  in
  let results = results_of_tainted_sinks env taints sinks in
  report_results env results;
  (taints, shape, var_env')

let results_from_arg_updates_at_exit enter_env exit_env : Sig.result list =
  (* TOOD: We need to get a map of `lval` to `Taint.arg`, and if an extension
   * of `lval` has new taints, then we can compute its correspoding `Taint.arg`
   * extension and generate a `ToLval` result too. *)
  exit_env |> Lval_env.seq_of_tainted
  |> Seq.map (fun (var, exit_var_ref) ->
         match Lval_env.find_var enter_env var with
         | None -> Seq.empty
         | Some (S.Ref ((`Clean | `None), _)) -> Seq.empty
         | Some (S.Ref (`Tainted enter_taints, _)) -> (
             (* For each lval in the enter_env, we get its `T.lval`, and check
              * if it got new taints at the exit_env. If so, we generate a 'ToLval'. *)
             match
               enter_taints |> Taints.elements
               |> List_.map_filter (fun taint ->
                      match taint.T.orig with
                      | T.Var lval -> Some lval
                      | _ -> None)
             with
             | []
             | _ :: _ :: _ ->
                 Seq.empty
             | [ lval ] ->
                 S.enum_in_ref exit_var_ref
                 |> Seq.filter_map (fun (offset, exit_taints) ->
                        let lval =
                          { lval with offset = lval.offset @ offset }
                        in
                        let new_taints = Taints.diff exit_taints enter_taints in
                        (* TODO: Also report if taints are _cleaned_. *)
                        if not (Taints.is_empty new_taints) then
                          Some
                            (Sig.ToLval (new_taints |> Taints.elements, lval))
                        else None)))
  |> Seq.concat |> List.of_seq

let check_tainted_at_exit_sinks node env =
  match !hook_check_tainted_at_exit_sinks with
  | None -> ()
  | Some hook -> (
      match hook env.config env.lval_env node with
      | None -> ()
      | Some (taints_at_exit, sink_matches_at_exit) ->
          results_of_tainted_sinks env taints_at_exit sink_matches_at_exit
          |> report_results env)

(*****************************************************************************)
(* Transfer *)
(*****************************************************************************)

let input_env ~enter_env ~(flow : F.cfg) mapping ni =
  let node = flow.graph#nodes#assoc ni in
  match node.F.n with
  | Enter -> enter_env
  | _else -> (
      let pred_envs =
        CFG.predecessors flow ni
        |> List_.map (fun (pi, _) -> mapping.(pi).D.out_env)
      in
      match pred_envs with
      | [] -> Lval_env.empty
      | [ penv ] -> penv
      | penv1 :: penvs -> List.fold_left Lval_env.union penv1 penvs)

let transfer :
    Lang.t ->
    Rule_options.t ->
    config ->
    Lval_env.t ->
    string option ->
    flow:F.cfg ->
    best_matches:TM.Best_matches.t ->
    java_props:java_props_cache ->
    Lval_env.t D.transfn =
 fun lang options config enter_env opt_name ~flow ~best_matches ~java_props
     (* the transfer function to update the mapping at node index ni *)
       mapping ni ->
  (* DataflowX.display_mapping flow mapping show_tainted; *)
  let in' : Lval_env.t = input_env ~enter_env ~flow mapping ni in
  let node = flow.graph#nodes#assoc ni in
  let env =
    {
      lang;
      options;
      config;
      fun_name = opt_name;
      lval_env = in';
      best_matches;
      java_props;
    }
  in
  let out' : Lval_env.t =
    match node.F.n with
    | NInstr x ->
        let taints, shape, lval_env' = check_tainted_instr env x in
        let opt_lval = LV.lval_of_instr_opt x in
        let lval_env' =
          match opt_lval with
          | Some lval ->
              (* We call `check_tainted_lval` here because the assigned `lval`
               * itself could be annotated as a source of taint. *)
              let taints, lval_shape, _sub, lval_env' =
                check_tainted_lval { env with lval_env = lval_env' } lval
              in
              (* We check if the instruction is a sink, and if so the taints
               * from the `lval` could make a finding. *)
              check_orig_if_sink env x.iorig taints lval_shape;
              lval_env'
          | None -> lval_env'
        in
        let lval_env' =
          match opt_lval with
          | Some lval ->
              if S.taints_and_shape_are_relevant taints shape then
                (* Instruction returns tainted data, add taints to lval.
                 * See [Taint_lval_env] for details. *)
                lval_env' |> Lval_env.add_shape lval taints shape
              else
                (* The RHS returns no taint, but taint could propagate by
                 * side-effect too. So, we check whether the taint assigned
                 * to 'lval' has changed to determine whether we need to
                 * clean 'lval' or not. *)
                let lval_taints_changed =
                  not (Lval_env.equal_by_lval in' lval_env' lval)
                in
                if lval_taints_changed then
                  (* The taint of 'lval' has changed, so there was a source or
                   * sanitizer acting by side-effect on this instruction. Thus we do NOT
                   * do anything more here. *)
                  lval_env'
                else
                  (* No side-effects on 'lval', and the instruction returns safe data,
                   * so we assume that the assigment acts as a sanitizer and therefore
                   * remove taints from lval. See [Taint_lval_env] for details. *)
                  Lval_env.clean lval_env' lval
          | None ->
              (* Instruction returns 'void' or its return value is ignored. *)
              lval_env'
        in
        lval_env'
    | NCond (_tok, e)
    | NThrow (_tok, e) ->
        let _taints, _shape, lval_env' = check_tainted_expr env e in
        lval_env'
    | NReturn (tok, e) ->
        (* TODO: Move most of this to check_tainted_return. *)
        let taints, shape, lval_env' = check_tainted_return env tok e in
        let results = results_of_tainted_return taints shape tok in
        report_results env results;
        lval_env'
    | NLambda params ->
        params
        |> List.fold_left
             (fun lval_env var ->
               (* This is a *new* variable, so we clean any taint that we may have
                * attached to it previously. This can happen when a lambda is called
                * inside a loop. *)
               let lval_env = Lval_env.clean lval_env (LV.lval_of_var var) in
               (* Now check if the parameter is itself a taint source. *)
               let _taints, _shape, lval_env =
                 check_tainted_var { env with lval_env } var
               in
               lval_env)
             in'
    | NGoto _
    | Enter
    | Exit
    | TrueNode _
    | FalseNode _
    | Join
    | NOther _
    | NTodo _ ->
        in'
  in
  check_tainted_at_exit_sinks node { env with lval_env = out' };
  Logs.debug (fun m ->
      m ~tags:transfer "Taint transfer %s\n  %s:\n  IN:  %s\n  OUT: %s"
        (env.fun_name ||| "<FUN>")
        (Display_IL.short_string_of_node_kind node.F.n)
        (Lval_env.to_string in') (Lval_env.to_string out'));
  { D.in_env = in'; out_env = out' }

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let (fixpoint :
      ?in_env:Lval_env.t ->
      ?name:Var_env.var ->
      Lang.t ->
      Rule_options.t ->
      config ->
      java_props_cache ->
      F.cfg ->
      mapping) =
 fun ?in_env ?name:opt_name lang options config java_props flow ->
  let init_mapping = DataflowX.new_node_array flow Lval_env.empty_inout in
  let enter_env =
    match in_env with
    | None -> Lval_env.empty
    | Some in_env -> in_env
  in
  let best_matches =
    (* Here we compute the "canonical" or "best" source/sanitizer/sink matches,
     * for each source/sanitizer/sink we check whether there is a "best match"
     * among all the potential matches in the CFG.
     * See NOTE "Best matches" *)
    TM.best_matches_in_nodes
      ~sub_matches_of_orig:(fun orig ->
        let sources =
          orig_is_source config orig |> List.to_seq
          |> Seq.filter (fun (m : R.taint_source TM.t) -> m.spec.source_exact)
          |> Seq.map (fun m -> TM.Any m)
        in
        let sanitizers =
          orig_is_sanitizer config orig
          |> List.to_seq
          |> Seq.filter (fun (m : R.taint_sanitizer TM.t) ->
                 m.spec.sanitizer_exact)
          |> Seq.map (fun m -> TM.Any m)
        in
        let sinks =
          orig_is_sink config orig |> List.to_seq
          |> Seq.filter (fun (m : R.taint_sink TM.t) -> m.spec.sink_exact)
          |> Seq.map (fun m -> TM.Any m)
        in
        sources |> Seq.append sanitizers |> Seq.append sinks)
      flow
  in
  (* THINK: Why I cannot just update mapping here ? if I do, the mapping gets overwritten later on! *)
  (* DataflowX.display_mapping flow init_mapping show_tainted; *)
  let end_mapping =
    DataflowX.fixpoint ~timeout:Limits_semgrep.taint_FIXPOINT_TIMEOUT
      ~eq_env:Lval_env.equal ~init:init_mapping
      ~trans:
        (transfer lang options config enter_env opt_name ~flow ~best_matches
           ~java_props)
        (* tainting is a forward analysis! *)
      ~forward:true ~flow
  in
  let exit_env = end_mapping.(flow.exit).D.out_env in
  ( results_from_arg_updates_at_exit enter_env exit_env |> fun results ->
    if results <> [] then config.handle_results opt_name results exit_env );
  end_mapping
