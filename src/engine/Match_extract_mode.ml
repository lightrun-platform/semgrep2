(* Cooper Pierce
 *
 * Copyright (c) 2022 r2c
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
module In = Input_to_core_j

let logger = Logging.get_logger [ __MODULE__ ]

(*****************************************************************************)
(* Purpose *)
(*****************************************************************************)
(* This module implements the logic for performing extractions dictated by any
   extract mode rules.

   This entails:
    - finding any matches in the provided targets generated by the given
      extract rules
    - combining (or not) these matches depending on the settings in the extract
      rule
    - producing new targets from the combined/processed matches
    - producing a mechanism for the caller to map matches found in the
      generated targets to matches in the original file
*)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)
(* A function which maps a match result from the *extracted* target
 * (e.g., '/tmp/extract-foo.rb') to a match result to the
 * *original* target (e.g., 'src/foo.erb').
 *
 * We could use instead:
 *
 *        (a -> a) -> a Report.match_result -> a Report.match_result
 *
 * although this is a bit less ergonomic for the caller.
 *)
type match_result_location_adjuster =
  Report.partial_profiling Report.match_result ->
  Report.partial_profiling Report.match_result

(* A type for nonempty lists *)
type 'a nonempty = Nonempty of 'a * 'a list

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let ( @: ) x (Nonempty (y, xs)) = Nonempty (x, y :: xs)
let nonempty_to_list (Nonempty (x, xs)) = x :: xs

(* from Run_semgrep *)
let mk_rule_table rules =
  rules |> Common.map (fun r -> (fst r.Rule.id, r)) |> Common.hash_of_list

(** Collects a list into a list of equivalence classes (themselves nonempty
    lists) according to the given equality predicate. `eq` must be an
    equivalence relation for correctness.
*)
let collect eq l =
  List.fold_left
    (fun collected x ->
      match
        List.fold_left
          (fun (checked, to_add) candidate_class ->
            match (to_add, candidate_class) with
            | None, _ -> (candidate_class :: checked, None)
            | Some x, Nonempty (y, _) ->
                if eq x y then ((x @: candidate_class) :: checked, None)
                else (candidate_class :: checked, Some x))
          ([], Some x) collected
      with
      | collected, None -> collected
      | collected, Some new_class -> Nonempty (new_class, []) :: collected)
    [] l

let extract_of_match erule_table match_ =
  Common.find_some_opt
    (fun (x, mvar) ->
      match Hashtbl.find_opt erule_table match_.Pattern_match.rule_id.id with
      | None -> None
      | Some r ->
          let (`Extract { Rule.extract; _ }) = r.Rule.mode in
          if x = extract then Some (r, Some mvar) else Some (r, None))
    match_.Pattern_match.env

type extract_range = {
  (* Offsets from start of file from which the extraction occured *)
  start_line : int;
  start_col : int;
  (* Byte index of start/end *)
  start_pos : int;
  end_pos : int;
}

let count_lines_and_trailing =
  Stdcompat.String.fold_left
    (fun (n, c) b ->
      match b with
      | '\n' -> (n + 1, 0)
      | __else__ -> (n, c + 1))
    (0, 0)

let offsets_of_mval extract_mvalue =
  Metavariable.mvalue_to_any extract_mvalue
  |> AST_generic_helpers.range_of_any_opt
  |> Option.map (fun ((start_loc : Tok.location), (end_loc : Tok.location)) ->
         let end_len = String.length end_loc.Tok.str in
         {
           start_pos = start_loc.pos.charpos;
           (* subtract 1 because lines are 1-indexed, so the
               offset is one less than the current line *)
           start_line = start_loc.pos.line - 1;
           start_col = start_loc.pos.column;
           end_pos = end_loc.pos.charpos + end_len;
         })

let check_includes_and_excludes rule extract_rule_ids =
  let r = rule.Rule.id in
  match extract_rule_ids with
  | None -> true
  | Some { Rule.required_rules; excluded_rules } ->
      ((* TODO: write: 'required_rules = []' instead of
          'List.length required_rules' and eliminate the
          counterproductive semgrep rules that prevent us from doing so. *)
       List.length required_rules =|= 0
      || List.exists
           (fun r' -> Rule.ID.ends_with (fst r) ~suffix:(fst r'))
           required_rules)
      && not
           (List.exists
              (fun r' -> Rule.ID.ends_with (fst r) ~suffix:(fst r'))
              excluded_rules)

(* Compute the rules that should be run for the extracted
   language.

   Input: all the rules known to the current semgrep scan. This allows
   us to identify them by their numeric index. This seems to be used to
   populate the rule_nums field that we normally get from pysemgrep.
   This is fragile. Let's try to get rid of this. Rules are identified
   by rule IDs which are strings. We should use that.

   Note: for normal targets, this decision is made on the Python
   side. Implementing that for extracted targets would be far more
   annoying, however. The main implication of selecting the rules
   here is, if your target is html and your dest lang is javascript,
   there is no way to ignore an html path for a specific javascript
   rule.*)
let rules_for_extracted_lang ~(all_rules : Rule.t list) extract_rule_ids =
  let rules_for_lang_tbl = Hashtbl.create 10 in
  let memo xlang =
    match Hashtbl.find_opt rules_for_lang_tbl xlang with
    | Some rules_for_lang -> rules_for_lang
    | None ->
        let rule_ids_for_lang =
          all_rules
          |> Common.mapi (fun i r -> (i, r))
          |> List.filter (fun (_i, r) ->
                 let r_lang = r.Rule.languages.target_analyzer in
                 match (xlang, r_lang) with
                 | Xlang.L (l, _), Xlang.L (rl, rls) ->
                     List.exists (fun x -> Lang.equal l x) (rl :: rls)
                 | Xlang.LSpacegrep, Xlang.LSpacegrep -> true
                 | Xlang.LAliengrep, Xlang.LAliengrep -> true
                 | Xlang.LRegex, Xlang.LRegex -> true
                 | ( ( Xlang.L _ | Xlang.LSpacegrep | Xlang.LAliengrep
                     | Xlang.LRegex ),
                     _ ) ->
                     false)
          |> List.filter (fun (_i, r) ->
                 check_includes_and_excludes r extract_rule_ids)
          |> Common.map fst
        in
        Hashtbl.add rules_for_lang_tbl xlang rule_ids_for_lang;
        rule_ids_for_lang
  in
  memo

let mk_extract_target extract_rule_ids dst_lang contents all_rules =
  let suffix = Xlang.to_string dst_lang in
  let f = Common.new_temp_file "extracted" suffix in
  Common2.write_file ~file:f contents;
  {
    In.path = f;
    language = dst_lang;
    rule_nums = rules_for_extracted_lang ~all_rules extract_rule_ids dst_lang;
  }

(* Unquote string *)
(* TODO: This is not yet implemented *)
let convert_from_unquote_to_string quoted_string =
  logger#error "unquote_string unimplemented";
  quoted_string

(* Unescapes JSON array string *)
let convert_from_json_array_to_string json =
  let json' = "{ \"semgrep_fake_payload\": " ^ json ^ "}" in
  Yojson.Basic.from_string json'
  |> Yojson.Basic.Util.member "semgrep_fake_payload"
  |> Yojson.Basic.Util.to_list
  |> Common.map Yojson.Basic.Util.to_string
  |> String.concat "\n"

(*****************************************************************************)
(* Error reporting *)
(*****************************************************************************)

let report_unbound_mvar (ruleid : Rule.rule_id) mvar m =
  let { Range.start; end_ } = Pattern_match.range m in
  logger#warning
    "The extract metavariable for rule %s (%s) wasn't bound in a match; \
     skipping extraction for this match [match was at bytes %d-%d]"
    (ruleid :> string)
    mvar start end_

let report_no_source_range erule =
  logger#error
    "In rule %s the extract metavariable (%s) did not have a corresponding \
     source range"
    (fst erule.Rule.id :> string)
    (let (`Extract { Rule.extract; _ }) = erule.mode in
     extract)

(*****************************************************************************)
(* Result mapping helpers *)
(*****************************************************************************)

let map_loc pos line col file (loc : Tok.location) =
  (* this _shouldn't_ be a fake location *)
  {
    loc with
    pos =
      {
        charpos = loc.pos.charpos + pos;
        line = loc.pos.line + line;
        column =
          (if loc.pos.line =|= 1 then loc.pos.column + col else loc.pos.column);
        file;
      };
  }

let map_taint_trace map_loc traces =
  let lift_map_loc f x =
    match x with
    | Tok.OriginTok loc -> Tok.OriginTok (f loc)
    | Tok.ExpandedTok (pp_loc, v_loc) -> Tok.ExpandedTok (f pp_loc, v_loc)
    | x -> x
  in
  let map_loc = lift_map_loc map_loc in
  let rec map_taint_call_trace trace =
    match trace with
    | Pattern_match.Toks tokens ->
        Pattern_match.Toks (Common.map map_loc tokens)
    | Pattern_match.Call { call_toks; intermediate_vars; call_trace } ->
        Pattern_match.Call
          {
            call_toks = Common.map map_loc call_toks;
            intermediate_vars = Common.map map_loc intermediate_vars;
            call_trace = map_taint_call_trace call_trace;
          }
  in
  Common.map
    (fun { Pattern_match.source_trace; tokens; sink_trace } ->
      {
        Pattern_match.source_trace = map_taint_call_trace source_trace;
        tokens = Common.map map_loc tokens;
        sink_trace = map_taint_call_trace sink_trace;
      })
    traces

let map_res map_loc tmpfile file
    (mr : Report.partial_profiling Report.match_result) =
  let matches =
    Common.map
      (fun (m : Pattern_match.t) ->
        {
          m with
          file;
          range_loc = Common2.pair map_loc m.range_loc;
          taint_trace =
            Option.map
              (Stdcompat.Lazy.map_val (map_taint_trace map_loc))
              m.taint_trace;
        })
      mr.matches
  in
  let errors =
    Report.ErrorSet.map
      (fun (e : Semgrep_error_code.error) -> { e with loc = map_loc e.loc })
      mr.errors
  in
  let extra =
    match mr.extra with
    | Debug { skipped_targets; profiling } ->
        let skipped_targets =
          Common.map
            (fun (st : Output_from_core_t.skipped_target) ->
              { st with path = (if st.path = tmpfile then file else st.path) })
            skipped_targets
        in
        Report.Debug
          { skipped_targets; profiling = { profiling with Report.file } }
    | Time { profiling } -> Time { profiling = { profiling with Report.file } }
    | No_info -> No_info
  in
  { Report.matches; errors; extra; explanations = [] }

(*****************************************************************************)
(* Main logic *)
(*****************************************************************************)

let extract_and_concat erule_table xtarget rules matches =
  matches
  (* Group the matches within this file by rule id.
   * TODO? dangerous use of =*= ?
   *)
  |> collect (fun m m' -> m.Pattern_match.rule_id =*= m'.Pattern_match.rule_id)
  |> Common.map (fun matches -> nonempty_to_list matches)
  (* Convert matches to the extract metavariable / bound value *)
  |> Common.map
       (Common.map_filter (fun m ->
            match extract_of_match erule_table m with
            | Some ({ mode = `Extract { Rule.extract; _ }; id = id, _; _ }, None)
              ->
                report_unbound_mvar id extract m;
                None
            | Some (r, Some mval) -> Some (r, mval)
            | None -> None))
  (* Factor out rule *)
  |> Common.map_filter (function
       | [] -> None
       | (r, _) :: _ as xs -> Some (r, Common.map snd xs))
  (* Convert mval match to offset of location in file *)
  |> Common.map (fun (r, mvals) ->
         ( r,
           Common.map_filter
             (fun mval ->
               let offsets = offsets_of_mval mval in
               if Option.is_none offsets then report_no_source_range r;
               offsets)
             mvals ))
  (* For every rule ... *)
  |> Common.map (fun (r, offsets) ->
         (* Sort matches by start position for merging *)
         List.fast_sort (fun x y -> Int.compare x.start_pos y.start_pos) offsets
         |> List.fold_left
              (fun acc curr ->
                match acc with
                | [] -> [ curr ]
                | last :: acc ->
                    (* Keep both when disjoint *)
                    if last.end_pos < curr.start_pos then curr :: last :: acc
                      (* Filter out already contained range; start of
                           last is before start of curr from sorting *)
                    else if curr.end_pos <= last.end_pos then last :: acc
                      (* Merge overlapping ranges *)
                    else { last with end_pos = curr.end_pos } :: acc)
              []
         |> List.rev
         (* Read the extracted text from the source file *)
         |> Common.map (fun { start_pos; start_line; start_col; end_pos } ->
                let contents_raw =
                  Common.with_open_infile xtarget.Xtarget.file (fun chan ->
                      let extract_size = end_pos - start_pos in
                      seek_in chan start_pos;
                      really_input_string chan extract_size)
                in
                (* Convert from JSON to plaintext, if required *)
                let contents =
                  let (`Extract { Rule.transform; _ }) = r.Rule.mode in
                  match transform with
                  | ConcatJsonArray ->
                      convert_from_json_array_to_string contents_raw
                  | Unquote -> convert_from_unquote_to_string contents_raw
                  | __else__ -> contents_raw
                in
                logger#trace
                  "Extract rule %s extracted the following from %s at bytes \
                   %d-%d\n\
                   %s"
                  (fst r.Rule.id :> string)
                  xtarget.file start_pos end_pos contents;
                (contents, map_loc start_pos start_line start_col xtarget.file))
         (* Combine the extracted snippets *)
         |> List.fold_left
              (fun (consumed_loc, contents, map_contents) (snippet, map_snippet) ->
                Buffer.add_string contents snippet;
                let len = String.length snippet in
                let snippet_lines, snippet_trailing =
                  count_lines_and_trailing snippet
                in
                ( {
                    consumed_loc with
                    start_pos = consumed_loc.start_pos + len;
                    start_line = consumed_loc.start_line + snippet_lines;
                    start_col = snippet_trailing;
                  },
                  contents,
                  (* Map results generated by running queries against the temp
                     file to results with ranges corresponding to the position
                     in the original source file.

                     For a tempfile generated from the concatenation of several
                     extracted snippets we accomplish this we by chaining
                     functions together, successively moving the offset along
                     from snippet to snippet if the position to map isn't in
                     the current one

                     In the event that a match spans multiple snippets it will
                     start at the correct start location, but the length with
                     dictate the end, so it may not exactly correspond.
                  *)
                  fun ({ Tok.pos = { charpos; _ }; _ } as loc) ->
                    if charpos < consumed_loc.start_pos then map_contents loc
                    else
                      (* For some reason, with the concat_json_string_array option, it needs a fix to point the right line *)
                      (* TODO: Find the reason of this behaviour and fix it properly *)
                      let line =
                        let (`Extract { Rule.transform; _ }) = r.Rule.mode in
                        match transform with
                        | ConcatJsonArray ->
                            loc.pos.line - consumed_loc.start_line - 1
                        | __else__ -> loc.pos.line - consumed_loc.start_line
                      in
                      map_snippet
                        {
                          loc with
                          pos =
                            {
                              loc.pos with
                              charpos = loc.pos.charpos - consumed_loc.start_pos;
                              line;
                              column =
                                (if line =|= 1 then
                                 loc.pos.column - consumed_loc.start_col
                                else loc.pos.column);
                            };
                        } ))
              ( { start_pos = 0; end_pos = 0; start_line = 0; start_col = 0 },
                Buffer.create 0,
                fun _ ->
                  (* cannot reach here because charpos of matches
                     cannot be negative and above length starts at 0 *)
                  raise Common.Impossible )
         |> fun (_, buf, map_loc) ->
         let contents = Buffer.contents buf in
         logger#trace
           "Extract rule %s combined matches from %s resulting in the following:\n\
            %s"
           (fst r.Rule.id :> string)
           xtarget.file contents;
         (* Write out the extracted text in a tmpfile *)
         let (`Extract { Rule.dst_lang; Rule.extract_rule_ids; _ }) = r.mode in
         let target =
           mk_extract_target extract_rule_ids dst_lang contents rules
         in
         (target, map_res map_loc target.path xtarget.file))

let extract_as_separate erule_table xtarget rules matches =
  matches
  |> Common.map_filter (fun m ->
         match extract_of_match erule_table m with
         | Some (erule, Some extract_mvalue) ->
             (* Note: char/line offset should be relative to the extracted
              * portion, _not_ the whole pattern!
              *)
             let* {
                    start_pos = start_extract_pos;
                    start_line = line_offset;
                    start_col = col_offset;
                    end_pos = end_extract_pos;
                  } =
               match offsets_of_mval extract_mvalue with
               | Some x -> Some x
               | None ->
                   report_no_source_range erule;
                   None
             in
             (* Read the extracted text from the source file *)
             let contents_raw =
               Common.with_open_infile m.file (fun chan ->
                   let extract_size = end_extract_pos - start_extract_pos in
                   seek_in chan start_extract_pos;
                   really_input_string chan extract_size)
             in
             (* Convert from JSON to plaintext, if required *)
             let contents =
               let (`Extract { Rule.transform; _ }) = erule.mode in
               match transform with
               | ConcatJsonArray ->
                   convert_from_json_array_to_string contents_raw
               | Unquote -> convert_from_unquote_to_string contents_raw
               | __else__ -> contents_raw
             in
             logger#trace
               "Extract rule %s extracted the following from %s at bytes %d-%d\n\
                %s"
               (m.rule_id.id :> string)
               m.file start_extract_pos end_extract_pos contents;
             (* Write out the extracted text in a tmpfile *)
             let (`Extract
                   { Rule.dst_lang; Rule.transform; Rule.extract_rule_ids; _ })
                 =
               erule.mode
             in
             let target =
               mk_extract_target extract_rule_ids dst_lang contents rules
             in
             (* For some reason, with the concat_json_string_array option, it needs a fix to point the right line *)
             (* TODO: Find the reason of this behaviour and fix it properly *)
             let map_loc =
               match transform with
               | ConcatJsonArray ->
                   map_loc start_extract_pos (line_offset - 1) col_offset
                     xtarget.Xtarget.file
               | __else__ ->
                   map_loc start_extract_pos line_offset col_offset
                     xtarget.Xtarget.file
             in
             Some (target, map_res map_loc target.path xtarget.file)
         | Some ({ mode = `Extract { Rule.extract; _ }; id = id, _; _ }, None)
           ->
             report_unbound_mvar id extract m;
             None
         | None ->
             (* Cannot fail to lookup rule in hashtable just created from rules
                used for query *)
             raise Common.Impossible)

(** This is the main function which performs extraction of the matches
   generated by extract mode rules.

   The resulting extracted regions will be combined appropiate to the rule's
   settings, and (a) target(s) along with a function to translate results back
   to the original file will be produced.
 *)
let extract_nested_lang ~match_hook ~timeout ~timeout_threshold
    (erules : Rule.extract_rule list) xtarget rules =
  let erule_table = mk_rule_table erules in
  let xconf = Match_env.default_xconfig in
  let res =
    Match_rules.check ~match_hook ~timeout ~timeout_threshold xconf
      (erules :> Rule.rules)
      xtarget
  in
  let separate_matches, combine_matches =
    res.matches
    |> Common.partition_either (fun (m : Pattern_match.t) ->
           match Hashtbl.find_opt erule_table m.rule_id.id with
           | Some erule -> (
               let (`Extract { Rule.reduce; _ }) = erule.mode in
               match reduce with
               | Separate -> Left m
               | Concat -> Right m)
           | None -> raise Impossible)
  in
  let separate =
    extract_as_separate erule_table xtarget rules separate_matches
  in
  let combined = extract_and_concat erule_table xtarget rules combine_matches in
  separate @ combined
