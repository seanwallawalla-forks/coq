(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Vernacexpr
open Vernacprop
open CErrors
open Util
open Pp
open Printer

module NamedDecl = Context.Named.Declaration
module CompactedDecl = Context.Compacted.Declaration

(** Idetop : an implementation of [Interface], i.e. mainly an interp
    function and a rewind function. *)


(** Signal handling: we postpone ^C during input and output phases,
    but make it directly raise a Sys.Break during evaluation of the request. *)

let catch_break = ref false

let init_signal_handler () =
  let f _ = if !catch_break then raise Sys.Break else Control.interrupt := true in
  Sys.set_signal Sys.sigint (Sys.Signal_handle f)

let pr_with_pid s = Printf.eprintf "[pid %d] %s\n%!" (Unix.getpid ()) s

let pr_error s = pr_with_pid s
let pr_debug s =
  if CDebug.(get_flag misc) then pr_with_pid s
let pr_debug_call q =
  if CDebug.(get_flag misc) then pr_with_pid ("<-- " ^ Xmlprotocol.pr_call q)
let pr_debug_answer q r =
  if CDebug.(get_flag misc) then pr_with_pid ("--> " ^ Xmlprotocol.pr_full_value q r)

(** Categories of commands *)

let coqide_known_option table = List.mem table [
  ["Printing";"Implicit"];
  ["Printing";"Coercions"];
  ["Printing";"Matching"];
  ["Printing";"Synth"];
  ["Printing";"Notations"];
  ["Printing";"Parentheses"];
  ["Printing";"All"];
  ["Printing";"Records"];
  ["Printing";"Existential";"Instances"];
  ["Printing";"Universes"];
  ["Printing";"Unfocused"];
  ["Diffs"]]

let is_known_option cmd = match cmd with
  | VernacSetOption (_, o, OptionSetTrue)
  | VernacSetOption (_, o, OptionSetString _)
  | VernacSetOption (_, o, OptionUnset) -> coqide_known_option o
  | _ -> false

let ide_cmd_warns ~id { CAst.loc; v } =
  let warn msg = Feedback.(feedback ~id (Message (Warning, loc, strbrk msg))) in
  if is_known_option v.expr then
    warn "Set this option from the IDE menu instead";
  if is_navigation_vernac v.expr || is_undo v.expr then
    warn "Use IDE navigation instead"

(** Interpretation (cf. [Ide_intf.interp]) *)

let ide_doc = ref None
let get_doc () = Option.get !ide_doc
let set_doc doc = ide_doc := Some doc

let add ((s,eid),(sid,verbose)) =
  let doc = get_doc () in
  let pa = Pcoq.Parsable.make (Stream.of_string s) in
  match Stm.parse_sentence ~doc sid ~entry:Pvernac.main_entry pa with
  | None -> assert false (* s may not be empty *)
  | Some ast ->
    let doc, newid, rc = Stm.add ~doc ~ontop:sid verbose ast in
    set_doc doc;
    let rc = match rc with Stm.NewAddTip -> CSig.Inl () | Stm.Unfocus id -> CSig.Inr id in
    ide_cmd_warns ~id:newid ast;
    (* All output is sent through the feedback mechanism rather than stdout/stderr *)
    newid, (rc, "")

let edit_at id =
  let doc = get_doc () in
  match Stm.edit_at ~doc id with
  | doc, Stm.NewTip -> set_doc doc; CSig.Inl ()
  | doc, Stm.Focus { Stm.start; stop; tip} -> set_doc doc; CSig.Inr (start, (stop, tip))

(* TODO: the "" parameter is a leftover of the times the protocol
 * used to include stderr/stdout output.
 *
 * Currently, we force all the output meant for the to go via the
 * feedback mechanism, and we don't manipulate stderr/stdout, which
 * are left to the client's discrection. The parameter is still there
 * as not to break the core protocol for this minor change, but it should
 * be removed in the next version of the protocol.
 *)
let query (route, (s,id)) =
  let pa = Pcoq.Parsable.make (Stream.of_string s) in
  let doc = get_doc () in
  Stm.query ~at:id ~doc ~route pa

let annotate phrase =
  let doc = get_doc () in
  let pa = Pcoq.Parsable.make (Stream.of_string phrase) in
  match Stm.parse_sentence ~doc (Stm.get_current_state ~doc) ~entry:Pvernac.main_entry pa with
  | None -> Richpp.richpp_of_pp ~width:78 (Pp.mt ())
  | Some ast ->
    (* XXX: Width should be a parameter of annotate... *)
    Richpp.richpp_of_pp ~width:78 (Ppvernac.pr_vernac ast)

(** Goal display *)

let hyp_next_tac sigma env decl =
  let id = NamedDecl.get_id decl in
  let ast = NamedDecl.get_type decl in
  let id_s = Names.Id.to_string id in
  let type_s = string_of_ppcmds (pr_ltype_env env sigma ast) in
  [
    ("clear "^id_s),("clear "^id_s^".");
    ("apply "^id_s),("apply "^id_s^".");
    ("exact "^id_s),("exact "^id_s^".");
    ("generalize "^id_s),("generalize "^id_s^".");
    ("absurd <"^id_s^">"),("absurd "^type_s^".")
  ] @ [
    ("discriminate "^id_s),("discriminate "^id_s^".");
    ("injection "^id_s),("injection "^id_s^".")
  ] @ [
    ("rewrite "^id_s),("rewrite "^id_s^".");
    ("rewrite <- "^id_s),("rewrite <- "^id_s^".")
  ] @ [
    ("elim "^id_s), ("elim "^id_s^".");
    ("inversion "^id_s), ("inversion "^id_s^".");
    ("inversion clear "^id_s), ("inversion_clear "^id_s^".")
  ]

let concl_next_tac =
  let expand s = (s,s^".") in
  List.map expand ([
    "intro";
    "intros";
    "intuition"
  ] @ [
    "reflexivity";
    "discriminate";
    "symmetry"
  ] @ [
    "assumption";
    "ring";
    "auto";
    "eauto";
    "tauto";
    "trivial";
    "decide equality";
    "simpl";
    "subst";
    "red";
    "split";
    "left";
    "right"
  ])

let process_goal sigma g =
  let env = Goal.V82.env sigma g in
  let min_env = Environ.reset_context env in
  let name = if Printer.print_goal_names () then Some (Names.Id.to_string (Termops.evar_suggested_name env sigma g)) else None in
  let ccl =
    pr_letype_env ~goal_concl_style:true env sigma (Goal.V82.concl sigma g)
  in
  let process_hyp d (env,l) =
    let d' = CompactedDecl.to_named_context d in
      (List.fold_right Environ.push_named d' env,
       (pr_compacted_decl env sigma d) :: l) in
  let (_env, hyps) =
    Context.Compacted.fold process_hyp
      (Termops.compact_named_context (Environ.named_context env)) ~init:(min_env,[]) in
  { Interface.goal_hyp = List.rev hyps; Interface.goal_ccl = ccl; Interface.goal_id = Goal.uid g; Interface.goal_name = name }

let process_goal_diffs diff_goal_map oldp nsigma ng =
  let open Evd in
  let name = if Printer.print_goal_names () then Some (Names.Id.to_string (Termops.evar_suggested_name (Global.env ()) nsigma ng)) else None in
  let og_s = match oldp with
    | Some oldp ->
      let Proof.{ sigma=osigma } = Proof.data oldp in
      (try Some { it = Evar.Map.find ng diff_goal_map; sigma = osigma }
       with Not_found -> None)
    | None -> None
  in
  let (hyps_pp_list, concl_pp) = Proof_diffs.diff_goal_ide og_s ng nsigma in
  { Interface.goal_hyp = hyps_pp_list; Interface.goal_ccl = concl_pp; Interface.goal_id = Goal.uid ng; Interface.goal_name = name }

let export_pre_goals Proof.{ sigma; goals; stack } process =
  let process = List.map (process sigma) in
  { Interface.fg_goals       = process goals
  ; Interface.bg_goals       = List.(map (fun (lg,rg) -> process lg, process rg)) stack
  ; Interface.shelved_goals  = process @@ Evd.shelf sigma
  ; Interface.given_up_goals = process (Evar.Set.elements @@ Evd.given_up sigma)
  }

let goals () =
  let doc = get_doc () in
  set_doc @@ Stm.finish ~doc;
  try
    let newp = Vernacstate.Declare.give_me_the_proof () in
    if Proof_diffs.show_diffs () then begin
      let oldp = Stm.get_prev_proof ~doc (Stm.get_current_state ~doc) in
      (try
        let diff_goal_map = Proof_diffs.make_goal_map oldp newp in
        Some (export_pre_goals Proof.(data newp) (process_goal_diffs diff_goal_map oldp))
       with Pp_diff.Diff_Failure msg ->
         Proof_diffs.notify_proof_diff_failure msg;
         Some (export_pre_goals Proof.(data newp) process_goal))
    end else
      Some (export_pre_goals Proof.(data newp) process_goal)
  with Vernacstate.Declare.NoCurrentProof -> None
  [@@ocaml.warning "-3"];;

let evars () =
  try
    let doc = get_doc () in
    set_doc @@ Stm.finish ~doc;
    let pfts = Vernacstate.Declare.give_me_the_proof () in
    let Proof.{ sigma } = Proof.data pfts in
    let exl = Evar.Map.bindings (Evd.undefined_map sigma) in
    let map_evar ev = { Interface.evar_info = string_of_ppcmds (pr_evar sigma ev); } in
    let el = List.map map_evar exl in
    Some el
  with Vernacstate.Declare.NoCurrentProof -> None
  [@@ocaml.warning "-3"]

let hints () =
  try
    let pfts = Vernacstate.Declare.give_me_the_proof () in
    let Proof.{ goals; sigma } = Proof.data pfts in
    match goals with
    | [] -> None
    | g :: _ ->
      let env = Goal.V82.env sigma g in
      let get_hint_hyp env d accu = hyp_next_tac sigma env d :: accu in
      let hint_hyps = List.rev (Environ.fold_named_context get_hint_hyp env ~init: []) in
      Some (hint_hyps, concl_next_tac)
  with Vernacstate.Declare.NoCurrentProof -> None
  [@@ocaml.warning "-3"]

(** Other API calls *)

let wait () =
  let doc = get_doc () in
  set_doc (Stm.wait ~doc)

let status force =
  (* We remove the initial part of the current [DirPath.t]
     (usually Top in an interactive session, cf "coqtop -top"),
     and display the other parts (opened sections and modules) *)
  set_doc (Stm.finish ~doc:(get_doc ()));
  if force then
    set_doc (Stm.join ~doc:(get_doc ()));
  let path =
    let l = Names.DirPath.repr (Lib.cwd ()) in
    List.rev_map Names.Id.to_string l
  in
  let proof =
    try Some (Names.Id.to_string (Vernacstate.Declare.get_current_proof_name ()))
    with Vernacstate.Declare.NoCurrentProof -> None
  in
  let allproofs =
    let l = Vernacstate.Declare.get_all_proof_names () in
    List.map Names.Id.to_string l
  in
  {
    Interface.status_path = path;
    Interface.status_proofname = proof;
    Interface.status_allproofs = allproofs;
    Interface.status_proofnum = Stm.current_proof_depth ~doc:(get_doc ());
  }
  [@@ocaml.warning "-3"]

let export_coq_object t = {
  Interface.coq_object_prefix = t.Search.coq_object_prefix;
  Interface.coq_object_qualid = t.Search.coq_object_qualid;
  Interface.coq_object_object =
    let env = Global.env () in
    let sigma = Evd.from_env env in
    Pp.string_of_ppcmds (pr_lconstr_env env sigma t.Search.coq_object_object)
}

let pattern_of_string ?env s =
  let env =
    match env with
    | None -> Global.env ()
    | Some e -> e
  in
  let constr = Pcoq.parse_string Pcoq.Constr.cpattern s in
  let (_, pat) = Constrintern.intern_constr_pattern env (Evd.from_env env) constr in
  pat

let dirpath_of_string_list s =
  let path = String.concat "." s in
  let qid = Pcoq.parse_string Pcoq.Constr.global path in
  let id =
    try Nametab.full_name_module qid
    with Not_found ->
      CErrors.user_err
        (str "Module " ++ str path ++ str " not found.")
  in
  id

let import_search_constraint = function
  | Interface.Name_Pattern s    -> Search.Name_Pattern (Str.regexp s)
  | Interface.Type_Pattern s    -> Search.Type_Pattern (pattern_of_string s)
  | Interface.SubType_Pattern s -> Search.SubType_Pattern (pattern_of_string s)
  | Interface.In_Module ms      -> Search.In_Module (dirpath_of_string_list ms)
  | Interface.Include_Blacklist -> Search.Include_Blacklist

let search flags =
  let pstate = Vernacstate.Declare.get_pstate () in
  let sigma, env = match pstate with
  | None -> let env = Global.env () in Evd.(from_env env, env)
  | Some p -> Declare.Proof.get_goal_context p 1 in
  List.map export_coq_object (Search.interface_search env sigma (
    List.map (fun (c, b) -> (import_search_constraint c, b)) flags)
  )
  [@@ocaml.warning "-3"]

let export_option_value = function
  | Goptions.BoolValue b   -> Interface.BoolValue b
  | Goptions.IntValue x    -> Interface.IntValue x
  | Goptions.StringValue s -> Interface.StringValue s
  | Goptions.StringOptValue s -> Interface.StringOptValue s

let import_option_value = function
  | Interface.BoolValue b   -> Goptions.BoolValue b
  | Interface.IntValue x    -> Goptions.IntValue x
  | Interface.StringValue s -> Goptions.StringValue s
  | Interface.StringOptValue s -> Goptions.StringOptValue s

let export_option_state s = {
  Interface.opt_sync  = true;
  Interface.opt_depr  = s.Goptions.opt_depr;
  Interface.opt_value = export_option_value s.Goptions.opt_value;
}

exception NotSupported of string

let proof_diff (diff_opt, sid) =
  let diff_opt = Proof_diffs.string_to_diffs diff_opt in
  let doc = get_doc () in
  match Stm.get_proof ~doc sid with
  | None -> CErrors.user_err (Pp.str "No proofs to diff.")
  | Some proof ->
      let old = Stm.get_prev_proof ~doc sid in
      Proof_diffs.diff_proofs ~diff_opt ?old proof

let debug_cmd = ref ""

let db_cmd cmd =
  debug_cmd := cmd

let get_options () =
  let table = Goptions.get_tables () in
  let fold key state accu = (key, export_option_state state) :: accu in
  Goptions.OptionMap.fold fold table []

let set_options options =
  let open Goptions in
  let iter (name, value) = match import_option_value value with
  | BoolValue b -> set_bool_option_value name b
  | IntValue i -> set_int_option_value name i
  | StringValue s -> set_string_option_value name s
  | StringOptValue (Some s) -> set_string_option_value name s
  | StringOptValue None -> unset_option_value_gen name
  in
  List.iter iter options

let about () = {
  Interface.coqtop_version = Coq_config.version;
  Interface.protocol_version = Xmlprotocol.protocol_version;
  Interface.release_date = "n/a";
  Interface.compile_date = "n/a";
}

let handle_exn (e, info) =
  let dummy = Stateid.dummy in
  let loc_of e = match Loc.get_loc e with
    | Some loc -> Some (Loc.unloc loc)
    | _        -> None in
  let mk_msg () = CErrors.iprint (e,info) in
  match e with
  | e ->
      match Stateid.get info with
      | Some (valid, _) -> valid, loc_of info, mk_msg ()
      | None -> dummy, loc_of info, mk_msg ()

let init =
  let initialized = ref false in
  fun file ->
   if !initialized then anomaly (str "Already initialized.")
   else begin
     let init_sid = Stm.get_current_state ~doc:(get_doc ()) in
     initialized := true;
     match file with
     | None -> init_sid
     | Some file ->
         let doc, initial_id, _ =
           get_doc (), init_sid, `NewTip in
         if Filename.check_suffix file ".v" then
           Stm.set_compilation_hints file;
         set_doc (Stm.finish ~doc);
         initial_id
   end

(* Retrocompatibility stuff, disabled since 8.7 *)
let interp ((_raw, verbose), s) =
  Stateid.dummy, CSig.Inr "The interp call has been disabled, please use Add."

(** When receiving the Quit call, we don't directly do an [exit 0],
    but rather set this reference, in order to send a final answer
    before exiting. *)
let quit = ref false

(** Disabled *)
let print_ast id = Xml_datatype.PCData "ERROR"

let idetop_make_cases iname =
  let qualified_iname = Libnames.qualid_of_string iname in
  let iref = Nametab.global_inductive qualified_iname in
  ComInductive.make_cases iref

(** Grouping all call handlers together + error handling *)
let eval_call c =
  let interruptible f x =
    catch_break := true;
    Control.check_for_interrupt ();
    let r = f x in
    catch_break := false;
    r
  in
  let handler = {
    Interface.add = interruptible add;
    Interface.edit_at = interruptible edit_at;
    Interface.query = interruptible query;
    Interface.goals = interruptible goals;
    Interface.evars = interruptible evars;
    Interface.hints = interruptible hints;
    Interface.status = interruptible status;
    Interface.search = interruptible search;
    Interface.proof_diff = interruptible proof_diff;
    Interface.db_cmd = interruptible db_cmd;   (* todo: interruptible or not? *)
    Interface.get_options = interruptible get_options;
    Interface.set_options = interruptible set_options;
    Interface.mkcases = interruptible idetop_make_cases;
    Interface.quit = (fun () -> quit := true);
    Interface.init = interruptible init;
    Interface.about = interruptible about;
    Interface.wait = interruptible wait;
    Interface.interp = interruptible interp;
    Interface.handle_exn = handle_exn;
    Interface.stop_worker = Stm.stop_worker;
    Interface.print_ast = print_ast;
    Interface.annotate = interruptible annotate;
  } in
  Xmlprotocol.abstract_eval_call handler c

(** Message dispatching.
    Since [coqidetop] starts 1 thread per slave, and each
    thread forwards feedback messages from the slave to the GUI on the same
    xml channel, we need mutual exclusion.  The mutex should be per-channel, but
    here we only use 1 channel. *)
let print_xml =
  let m = Mutex.create () in
  fun oc xml ->
    CThread.with_lock m ~scope:(fun () ->
        if !Flags.xml_debug then
          Printf.printf "SENT --> %s\n%!" (Xml_printer.to_string_fmt xml);
        try Control.protect_sigalrm (Xml_printer.print oc) xml
        with e -> let e = Exninfo.capture e in Exninfo.iraise e)

let slave_feeder fmt xml_oc msg =
  let xml = Xmlprotocol.(of_feedback fmt msg) in
  print_xml xml_oc xml

(** The main loop *)

(** Exceptions during eval_call should be converted into [Interface.Fail]
    messages by [handle_exn] above. Otherwise, we die badly, without
    trying to answer malformed requests. *)

let msg_format = ref (fun () ->
    let width = Option.default 72 (Topfmt.get_margin ()) in
    Xmlprotocol.Richpp { width; depth = max_int }
  )

(* The loop ignores the command line arguments as the current model delegates
   its handing to the toplevel container. *)
let loop ( { Coqtop.run_mode; color_mode },_) ~opts:_ state =
  match run_mode with
  | Coqtop.Batch -> exit 0
  | Coqtop.(Query PrintTags) -> Coqtop.print_style_tags color_mode; exit 0
  | Coqtop.(Query _) -> Printf.eprintf "Unknown query"; exit 1
  | Coqtop.Interactive ->
  let open Vernac.State in
  set_doc state.doc;
  init_signal_handler ();
  catch_break := false;
  let in_ch, out_ch = Spawned.get_channels () in
  let xml_oc        = Xml_printer.make (Xml_printer.TChannel out_ch) in
  let in_lb         = Lexing.from_function (fun s len ->
                      CThread.thread_friendly_read in_ch s ~off:0 ~len) in
  (* SEXP parser make *)
  let xml_ic        = Xml_parser.make (Xml_parser.SLexbuf in_lb) in
  let () = Xml_parser.check_eof xml_ic false in
  ignore (Feedback.add_feeder (slave_feeder (!msg_format ()) xml_oc));
  let process_xml_msg xml_ic xml_oc out_ch =
    try
      let xml_query = Xml_parser.parse xml_ic in
      if !Flags.xml_debug then
        pr_with_pid (Xml_printer.to_string_fmt xml_query);
      let Xmlprotocol.Unknown q = Xmlprotocol.to_call xml_query in
      let () = pr_debug_call q in
      let r  = eval_call q in
      let () = pr_debug_answer q r in
(*       pr_with_pid (Xml_printer.to_string_fmt (Xmlprotocol.of_answer q r)); *)
      print_xml xml_oc Xmlprotocol.(of_answer (!msg_format ()) q r);
      flush out_ch
    with
      | Xml_parser.Error (Xml_parser.Empty, _) ->
        pr_debug "End of input, exiting gracefully.";
        exit 0
      | Xml_parser.Error (err, loc) ->
        pr_error ("XML syntax error: " ^ Xml_parser.error_msg err)
      | Serialize.Marshal_error (msg,node) ->
        pr_error "Unexpected XML message";
        pr_error ("Expected XML node: " ^ msg);
        pr_error ("XML tree received: " ^ Xml_printer.to_string_fmt node)
      | any ->
        pr_debug ("Fatal exception in coqtop:\n" ^ Printexc.to_string any);
        exit 1
  in

  (* output the xml message using the feeder, note that the
     xmlprotocol file doesn't depend on vernac thus it has no access
     to DebugHook data, we may want to fix that. *)
  let ltac_debug_answer ans =
    let tag, msg =
      let open DebugHook.Answer in
      match ans with
      | Prompt msg -> "prompt", msg
      | Goal msg -> "goal", (str "Goal:" ++ fnl () ++ msg)
      | Output msg -> "output", msg
    in
    print_xml xml_oc Xmlprotocol.(of_ltac_debug_answer ~tag msg) in

  (* XXX: no need to have a ref here *)
  let ltac_debug_parse () =
    let raw_cmd =
      process_xml_msg xml_ic xml_oc out_ch;
      !debug_cmd
    in
    let open DebugHook in
    match Action.parse raw_cmd with
    | Ok act -> act
    | Error error -> ltac_debug_answer (Answer.Output (str error)); Action.Failed
  in

  DebugHook.Intf.(set
      { read_cmd = ltac_debug_parse
      ; submit_answer = ltac_debug_answer
      });

  while not !quit do
    process_xml_msg xml_ic xml_oc out_ch
  done;
  pr_debug "Exiting gracefully.";
  exit 0

let rec parse = function
  | "--help-XML-protocol" :: rest ->
        Xmlprotocol.document Xml_printer.to_string_fmt; exit 0
  | "--xml_format=Ppcmds" :: rest ->
        msg_format := (fun () -> Xmlprotocol.Ppcmds); parse rest
  | x :: rest ->
     if String.length x > 0 && x.[0] = '-' then
       (prerr_endline ("Unknown option " ^ x); exit 1)
     else
       x :: parse rest
  | [] -> []

let coqidetop_specific_usage = Usage.{
  executable_name = "coqidetop";
  extra_args = "";
  extra_options = "\n\
coqidetop specific options:\n\
\n  --xml_formatinclude dir           (idem)\
\n  --xml_format=Ppcmds    serialize pretty printing messages using the std_ppcmds format\
\n  --help-XML-protocol    print documentation of the Coq XML protocol\n"
}

let islave_parse extra_args =
  let open Coqtop in
  let ({ run_mode; color_mode }, stm_opts), extra_args = coqtop_toplevel.parse_extra extra_args in
  let extra_args = parse extra_args in
  (* One of the role of coqidetop is to find the name of buffers to open *)
  (* in the command line; Coqide is waiting these names on stdout *)
  (* (see filter_coq_opts in coq.ml), so we send them now *)
  print_string (String.concat "\n" extra_args);
  ( { Coqtop.run_mode; color_mode }, stm_opts), []

let islave_init ( { Coqtop.run_mode; color_mode }, stm_opts) injections ~opts =
  if run_mode = Coqtop.Batch then Flags.quiet := true;
  Coqtop.init_toploop opts stm_opts injections

let islave_default_opts = Coqargs.default

let () =
  let open Coqtop in
  let custom = {
      parse_extra = islave_parse ;
      usage = coqidetop_specific_usage;
      init_extra = islave_init;
      run = loop;
      initial_args = islave_default_opts } in
  start_coq custom
