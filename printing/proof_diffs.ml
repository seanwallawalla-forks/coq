(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

(*
Displays the differences between successive proof steps in coqtop and CoqIDE.
Proof General requires minor changes to make the diffs visible, but this code
shouldn't break the existing version of PG.  See pp_diff.ml for details on how
the diff works.

Diffs are computed for the hypotheses and conclusion of each goal in the new
proof with its matching goal in the old proof.

Diffs can be enabled in coqtop with 'Set Diffs "on"|"off"|"removed"' or
'-diffs on|off|removed' on the OS command line.  In CoqIDE, they can be enabled
from the View menu.  The "on" option shows only the new item with added text,
while "removed" shows each modified item twice--once with the old value showing
removed text and once with the new value showing added text.

In CoqIDE, colors and highlights can be set in the Edit/Preferences/Tags panel.
For coqtop, these can be set through the COQ_COLORS environment variable.

Limitations/Possible enhancements:

- coqtop colors were chosen for white text on a black background.  They're
not the greatest.  I didn't want to change the existing green highlight.
Suggestions welcome.

- coqtop underlines removed text because (per Wikipedia) the ANSI escape code
for strikeout is not commonly supported (it didn't work on my system).  CoqIDE
uses strikeout on removed text.
*)

open Pp_diff

let term_color = ref true

let write_color_enabled enabled =
  term_color := enabled

let color_enabled () = !term_color

type diffOpt = DiffOff | DiffOn | DiffRemoved

let diffs_to_string = function
  | DiffOff -> "off"
  | DiffOn -> "on"
  | DiffRemoved -> "removed"


let assert_color_enabled () =
  if not (color_enabled ()) then
    CErrors.user_err
      Pp.(str "Enabling Diffs requires setting the \"-color\" command line argument to \"on\" or \"auto\".")

let string_to_diffs = function
  | "off" -> DiffOff
  | "on" -> assert_color_enabled (); DiffOn
  | "removed" -> assert_color_enabled (); DiffRemoved
  | _ -> CErrors.user_err Pp.(str "Diffs option only accepts the following values: \"off\", \"on\", \"removed\".")

let opt_name = ["Diffs"]

let diff_option =
  Goptions.declare_interpreted_string_option_and_ref
    ~depr:false
    ~key:opt_name
    ~value:DiffOff
    string_to_diffs
    diffs_to_string

let show_diffs () = match diff_option () with DiffOff -> false | _ -> true
let show_removed () = match diff_option () with DiffRemoved -> true | _ -> false


(* DEBUG/UNIT TEST *)
let cfprintf oc = Printf.(kfprintf (fun oc -> fprintf oc "") oc)
let log_out_ch = ref stdout
[@@@ocaml.warning "-32"]
let cprintf s = cfprintf !log_out_ch s
[@@@ocaml.warning "+32"]

let tokenize_string s =
  (* todo: cLexer changes buff as it proceeds.  Seems like that should be saved, too.
  But I don't understand how it's used--it looks like things get appended to it but
  it never gets cleared. *)
  let rec stream_tok acc str =
    let e = LStream.next str in
    if Tok.(equal e EOI) then
      List.rev acc
    else
      stream_tok ((Tok.extract_string true e) :: acc) str
  in
  let st = CLexer.Lexer.State.get () in
  try
    let istr = Stream.of_string s in
    let lex = CLexer.LexerDiff.tok_func istr in
    let toks = stream_tok [] lex in
    CLexer.Lexer.State.set st;
    toks
  with exn ->
    CLexer.Lexer.State.set st;
    raise (Diff_Failure "Input string is not lexable");;

type hyp_info = {
  idents: string list;
  rhs_pp: Pp.t;
  mutable done_: bool;
}

(* Generate the diffs between the old and new hyps.
   This works by matching lines with the hypothesis name and diffing the right-hand side.
   Lines that have multiple names such as "n, m : nat" are handled specially to account
   for, say, the addition of m to a pre-existing "n : nat".
 *)
let diff_hyps o_line_idents o_map n_line_idents n_map =
  let rv : Pp.t list ref = ref [] in

  let is_done ident map = (CString.Map.find ident map).done_ in
  let exists ident map =
    try let _ = CString.Map.find ident map in true
    with Not_found -> false in
  let contains l ident = try [List.find (fun x  -> x = ident) l] with Not_found -> [] in

  let output old_ids_uo new_ids =
    (* use the order from the old line in case it's changed in the new *)
    let old_ids = if old_ids_uo = [] then [] else
      let orig = (CString.Map.find (List.hd old_ids_uo) o_map).idents in
      List.concat (List.map (contains orig) old_ids_uo)
    in

    let setup ids map = if ids = [] then ("", Pp.mt ()) else
      let open Pp in
      let rhs_pp = (CString.Map.find (List.hd ids) map).rhs_pp in
      let pp_ids = List.map (fun x -> str x) ids in
      let hyp_pp = List.fold_left (fun l1 l2 -> l1 ++ str ", " ++ l2) (List.hd pp_ids) (List.tl pp_ids) ++ rhs_pp in
      (string_of_ppcmds hyp_pp, hyp_pp)
    in

    let (o_line, o_pp) = setup old_ids o_map in
    let (n_line, n_pp) = setup new_ids n_map in

    let hyp_diffs = diff_str ~tokenize_string o_line n_line in
    let (has_added, has_removed) = has_changes hyp_diffs in
    if show_removed () && has_removed then begin
      List.iter (fun x -> (CString.Map.find x o_map).done_ <- true) old_ids;
      rv := (add_diff_tags `Removed o_pp hyp_diffs) :: !rv;
    end;
    if n_line <> "" then begin
      List.iter (fun x -> (CString.Map.find x n_map).done_ <- true) new_ids;
      rv := (add_diff_tags `Added n_pp hyp_diffs) :: !rv
    end
  in

  (* process identifier level diff *)
  let process_ident_diff diff =
    let (dtype, ident) = get_dinfo diff in
    match dtype with
    | `Removed ->
      if dtype = `Removed then begin
        let o_idents = (CString.Map.find ident o_map).idents in
        (* only show lines that have all idents removed here; other removed idents appear later *)
        if show_removed () && not (is_done ident o_map) &&
            List.for_all (fun x -> not (exists x n_map)) o_idents then
          output (List.rev o_idents) []
      end
    | _ -> begin (* Added or Common case *)
      let n_idents = (CString.Map.find ident n_map).idents in

      (* Process a new hyp line, possibly splitting it.  Duplicates some of
         process_ident iteration, but easier to understand this way *)
      let process_line ident2 =
        if not (is_done ident2 n_map) then begin
          let n_ids_list : string list ref = ref [] in
          let o_ids_list : string list ref = ref [] in
          let fst_omap_idents = ref None in
          let add ids id map =
            ids := id :: !ids;
            (CString.Map.find id map).done_ <- true in

          (* get identifiers shared by one old and one new line, plus
             other Added in new and other Removed in old *)
          let process_split ident3 =
            if not (is_done ident3 n_map) then begin
              let this_omap_idents = try Some (CString.Map.find ident3 o_map).idents
                                    with Not_found -> None in
              if !fst_omap_idents = None then
                fst_omap_idents := this_omap_idents;
              match (!fst_omap_idents, this_omap_idents) with
              | (Some fst, Some this) when fst == this ->  (* yes, == *)
                add n_ids_list ident3 n_map;
                (* include, in old order, all undone Removed idents in old *)
                List.iter (fun x -> if x = ident3 || not (is_done x o_map) && not (exists x n_map) then
                                    (add o_ids_list x o_map)) fst
              | (_, None) ->
                add n_ids_list ident3 n_map (* include all undone Added idents in new *)
              | _ -> ()
            end in
          List.iter process_split n_idents;
          output (List.rev !o_ids_list) (List.rev !n_ids_list)
        end in
      List.iter process_line n_idents (* O(n^2), so sue me *)
    end in

  let cvt s = Array.of_list (List.concat s) in
  let ident_diffs = diff_strs (cvt o_line_idents) (cvt n_line_idents) in
  List.iter process_ident_diff ident_diffs;
  List.rev !rv;;


type 'a hyp = (Names.Id.t Context.binder_annot list * 'a option * 'a)
type 'a reified_goal = { name: string; ty: 'a; hyps: 'a hyp list; env : Environ.env; sigma: Evd.evar_map }

(* XXX: Port to proofview, one day. *)
(* open Proofview *)
module CDC = Context.Compacted.Declaration

let to_tuple : Constr.compacted_declaration -> (Names.Id.t Context.binder_annot list * 'pc option * 'pc) =
  let open CDC in function
    | LocalAssum(idl, tm)   -> (idl, None, EConstr.of_constr tm)
    | LocalDef(idl,tdef,tm) -> (idl, Some (EConstr.of_constr tdef), EConstr.of_constr tm);;

(* XXX: Very unfortunately we cannot use the Proofview interface as
   Proof is still using the "legacy" one. *)
let process_goal_concl sigma g : EConstr.t * Environ.env =
  let env  = Goal.V82.env   sigma g in
  let ty   = Goal.V82.concl sigma g in
  (ty, env)

let process_goal sigma g : EConstr.t reified_goal =
  let env  = Goal.V82.env   sigma g in
  let ty   = Goal.V82.concl sigma g in
  let name = Goal.uid g             in
  (* compaction is usually desired [eg for better display] *)
  let hyps      = Termops.compact_named_context (Environ.named_context env) in
  let hyps      = List.map to_tuple hyps in
  { name; ty; hyps; env; sigma };;

let pr_letype_env ?lax ?goal_concl_style env sigma ?impargs t =
  Ppconstr.pr_lconstr_expr env sigma
    (Constrextern.extern_type ?lax ?goal_concl_style env sigma ?impargs t)

let pp_of_type env sigma ty =
  pr_letype_env ~goal_concl_style:true env sigma ty

let pr_leconstr_env ?lax ?inctx ?scope env sigma t =
  Ppconstr.pr_lconstr_expr env sigma (Constrextern.extern_constr ?lax ?inctx ?scope env sigma t)

let pr_econstr_env ?lax ?inctx ?scope env sigma t =
  Ppconstr.pr_constr_expr env sigma (Constrextern.extern_constr ?lax ?inctx ?scope env sigma t)

let pr_lconstr_env ?lax ?inctx ?scope env sigma c =
  pr_leconstr_env ?lax ?inctx ?scope env sigma (EConstr.of_constr c)

let diff_concl ?og_s nsigma ng =
  let open Evd in
  let o_concl_pp = match og_s with
    | Some { it=og; sigma=osigma } ->
      let (oty, oenv) = process_goal_concl osigma og in
      pp_of_type oenv osigma oty
    | None -> Pp.mt()
  in
  let (nty, nenv) = process_goal_concl nsigma ng in
  let n_concl_pp = pp_of_type nenv nsigma nty in

  let show_removed = Some (show_removed ()) in

  diff_pp_combined ~tokenize_string ?show_removed o_concl_pp n_concl_pp

(* fetch info from a goal, returning (idents, map, concl_pp) where
idents is a list with one entry for each hypothesis, in which each entry
is the list of idents on the lhs of the hypothesis.  map is a map from
ident to hyp_info reoords.  For example: for the hypotheses:
  b : bool
  n, m : nat

idents will be [ ["b"]; ["n"; "m"] ]

map will contain:
  "b" -> { ["b"], Pp.t for ": bool"; false }
  "n" -> { ["n"; "m"], Pp.t for ": nat"; false }
  "m" -> { ["n"; "m"], Pp.t for ": nat"; false }
 where the last two entries share the idents list.

concl_pp is the conclusion as a Pp.t
*)
let goal_info goal sigma =
  let map = ref CString.Map.empty in
  let line_idents = ref [] in
  let build_hyp_info env sigma hyp =
    let (names, body, ty) = hyp in
    let open Pp in
    let idents = List.map (fun x -> Names.Id.to_string x.Context.binder_name) names in

    line_idents := idents :: !line_idents;
    let mid = match body with
    | Some c ->
      let pb = pr_leconstr_env env sigma c in
      let pb = if EConstr.isCast sigma c then surround pb else pb in
      str " := " ++ pb
    | None -> mt() in
    let ts = pp_of_type env sigma ty in
    let rhs_pp = mid ++ str " : " ++ ts in

    let make_entry () = { idents; rhs_pp; done_ = false } in
    List.iter (fun ident -> map := (CString.Map.add ident (make_entry ()) !map); ()) idents
  in

  try
    let { ty=ty; hyps=hyps; env=env } = process_goal sigma goal in
    List.iter (build_hyp_info env sigma) (List.rev hyps);
    let concl_pp = pp_of_type env sigma ty in
    ( List.rev !line_idents, !map, concl_pp )
  with _ -> ([], !map, Pp.mt ());;

let diff_goal_info o_info n_info =
  let (o_line_idents, o_hyp_map, o_concl_pp) = o_info in
  let (n_line_idents, n_hyp_map, n_concl_pp) = n_info in
  let show_removed = Some (show_removed ()) in
  let concl_pp = diff_pp_combined ~tokenize_string ?show_removed o_concl_pp n_concl_pp in

  let hyp_diffs_list = diff_hyps o_line_idents o_hyp_map n_line_idents n_hyp_map in
  (hyp_diffs_list, concl_pp)

let hyp_list_to_pp hyps =
  let open Pp in
  match hyps with
  | h :: tl -> List.fold_left (fun x y -> x ++ cut () ++ y) h tl
  | [] -> mt ();;

let unwrap g_s =
  match g_s with
  | Some g_s ->
    let goal = Evd.sig_it g_s in
    let sigma = Tacmach.project g_s in
    goal_info goal sigma
  | None -> ([], CString.Map.empty, Pp.mt ())

let diff_goal_ide og_s ng nsigma =
  diff_goal_info (unwrap og_s) (goal_info ng nsigma)

let diff_goal ?og_s ng ns =
  let (hyps_pp_list, concl_pp) = diff_goal_info (unwrap og_s) (goal_info ng ns) in
  let open Pp in
  v 0 (
    (hyp_list_to_pp hyps_pp_list) ++ cut () ++
    str "============================" ++ cut () ++
    concl_pp);;


(*** Code to determine which calls to compare between the old and new proofs ***)

open Constrexpr
open Names
open CAst

(* Compare the old and new proof trees to identify the correspondence between
new and old goals.  Returns a map from the new evar name to the old,
e.g. "Goal2" -> "Goal1".  Assumes that proof steps only rewrite CEvar nodes
and that CEvar nodes cannot contain other CEvar nodes.

The comparison works this way:
1. Traverse the old and new trees together (ogname = "", ot != nt):
- if the old and new trees both have CEvar nodes, add an entry to the map from
  the new evar name to the old evar name.  (Position of goals is preserved but
  evar names may not be--see below.)
- if the old tree has a CEvar node and the new tree has a different type of node,
  we've found a changed goal.  Set ogname to the evar name of the old goal and
  go to step 2.
- any other mismatch violates the assumptions, raise an exception
2. Traverse the new tree from the point of the difference (ogname <> "", ot = nt).
- if the node is a CEvar, generate a map entry from the new evar name to ogname.

Goal ids for unchanged goals appear to be preserved across proof steps.
However, the evar name associated with a goal id may change in a proof step
even if that goal is not changed by the tactic.  You can see this by enabling
the call to db_goal_map and entering the following:

  Parameter P : nat -> Prop.
  Goal (P 1 /\ P 2 /\ P 3) /\ P 4.
  split.
  Show Proof.
  split.
  Show Proof.

  Which gives you this summarized output:

  > split.
  New Goals: 3 -> Goal  4 -> Goal0              <--- goal 4 is "Goal0"
  Old Goals: 1 -> Goal
  Goal map: 3 -> 1  4 -> 1
  > Show Proof.
  (conj ?Goal ?Goal0)                           <--- goal 4 is the rightmost goal in the proof
  > split.
  New Goals: 6 -> Goal0  7 -> Goal1  4 -> Goal  <--- goal 4 is now "Goal"
  Old Goals: 3 -> Goal  4 -> Goal0
  Goal map: 6 -> 3  7 -> 3
  > Show Proof.
  (conj (conj ?Goal0 ?Goal1) ?Goal)             <--- goal 4 is still the rightmost goal in the proof
 *)
(* todo: fails for issue 14425 on a "clear". Perhaps this can be fixed by computing
   the goal map directly from the kernel evars, which is likely much simpler *)
let match_goals ot nt =
  let nevar_to_oevar = ref CString.Map.empty in
  (* ogname is "" when there is no difference on the current path.
     It's set to the old goal's evar name once a rewritten goal is found,
     at which point the code only searches for the replacing goals
     (and ot is set to nt). *)
  let iter2 f l1 l2 =
    if List.length l1 = (List.length l2) then
      List.iter2 f l1 l2
  in
  let rec match_goals_r ogname ot nt =
    let constr_expr ogname exp exp2 =
      match_goals_r ogname exp.v exp2.v
    in
    let constr_expr_opt ogname exp exp2 =
      match exp, exp2 with
      | Some expa, Some expb -> constr_expr ogname expa expb
      | None, None -> ()
      | _, _ -> raise (Diff_Failure "Unable to match goals between old and new proof states (1)")
    in
    let constr_arr ogname arr_exp arr_exp2 =
      let len = Array.length arr_exp in
      if len <> Array.length arr_exp2 then
        raise (Diff_Failure "Unable to match goals between old and new proof states (6)");
      for i = 0 to len -1 do
        constr_expr ogname arr_exp.(i) arr_exp2.(i)
      done
    in
    let local_binder_expr ogname exp exp2 =
      match exp, exp2 with
      | CLocalAssum (nal,bk,ty), CLocalAssum(nal2,bk2,ty2) ->
        constr_expr ogname ty ty2
      | CLocalDef (n,c,t), CLocalDef (n2,c2,t2) ->
        constr_expr ogname c c2;
        constr_expr_opt ogname t t2
      | CLocalPattern p, CLocalPattern p2 ->
        let ty = match p.v with CPatCast (_,ty) -> Some ty | _ -> None in
        let ty2 = match p2.v with CPatCast (_,ty) -> Some ty | _ -> None in
        constr_expr_opt ogname ty ty2
      | _, _ -> raise (Diff_Failure "Unable to match goals between old and new proof states (2)")
    in
    let recursion_order_expr ogname exp exp2 =
      match exp.CAst.v, exp2.CAst.v with
      | CStructRec _, CStructRec _ -> ()
      | CWfRec (_,c), CWfRec (_,c2) ->
        constr_expr ogname c c2
      | CMeasureRec (_,m,r), CMeasureRec (_,m2,r2) ->
        constr_expr ogname m m2;
        constr_expr_opt ogname r r2
      | _, _ -> raise (Diff_Failure "Unable to match goals between old and new proof states (3)")
    in
    let fix_expr ogname exp exp2 =
      let (l,ro,lb,ce1,ce2), (l2,ro2,lb2,ce12,ce22) = exp,exp2 in
        Option.iter2 (recursion_order_expr ogname) ro ro2;
        iter2 (local_binder_expr ogname) lb lb2;
        constr_expr ogname ce1 ce12;
        constr_expr ogname ce2 ce22
    in
    let cofix_expr ogname exp exp2 =
      let (l,lb,ce1,ce2), (l2,lb2,ce12,ce22) = exp,exp2 in
        iter2 (local_binder_expr ogname) lb lb2;
        constr_expr ogname ce1 ce12;
        constr_expr ogname ce2 ce22
    in
    let case_expr ogname exp exp2 =
      let (ce,l,cp), (ce2,l2,cp2) = exp,exp2 in
      constr_expr ogname ce ce2
    in
    let branch_expr ogname exp exp2 =
      let (cpe,ce), (cpe2,ce2) = exp.v,exp2.v in
        constr_expr ogname ce ce2
    in
    let constr_notation_substitution ogname exp exp2 =
      let (ce, cel, cp, lb), (ce2, cel2, cp2, lb2) = exp, exp2 in
      iter2 (constr_expr ogname) ce ce2;
      iter2 (fun a a2 -> iter2 (constr_expr ogname) a a2) cel cel2;
      iter2 (fun a a2 -> iter2 (local_binder_expr ogname) a a2) lb lb2
    in
    begin
    match ot, nt with
    | CRef (ref,us), CRef (ref2,us2) -> ()
    | CFix (id,fl), CFix (id2,fl2) ->
      iter2 (fix_expr ogname) fl fl2
    | CCoFix (id,cfl), CCoFix (id2,cfl2) ->
      iter2 (cofix_expr ogname) cfl cfl2
    | CProdN (bl,c2), CProdN (bl2,c22)
    | CLambdaN (bl,c2), CLambdaN (bl2,c22) ->
      iter2 (local_binder_expr ogname) bl bl2;
      constr_expr ogname c2 c22
    | CLetIn (na,c1,t,c2), CLetIn (na2,c12,t2,c22) ->
      constr_expr ogname c1 c12;
      constr_expr_opt ogname t t2;
      constr_expr ogname c2 c22
    | CAppExpl ((ref,us),args), CAppExpl ((ref2,us2),args2) ->
      iter2 (constr_expr ogname) args args2
    | CApp (f,args), CApp (f2,args2) ->
      constr_expr ogname f f2;
      iter2 (fun a a2 -> let (c, _) = a and (c2, _) = a2 in
          constr_expr ogname c c2) args args2
    | CProj (expl,f,args,c), CProj (expl2,f2,args2,c2) ->
      iter2 (fun a a2 -> let (c, _) = a and (c2, _) = a2 in
          constr_expr ogname c c2) args args2;
      constr_expr ogname c c2;
    | CRecord fs, CRecord fs2 ->
      iter2 (fun a a2 -> let (_, c) = a and (_, c2) = a2 in
          constr_expr ogname c c2) fs fs2
    | CCases (sty,rtnpo,tms,eqns), CCases (sty2,rtnpo2,tms2,eqns2) ->
        constr_expr_opt ogname rtnpo rtnpo2;
        iter2 (case_expr ogname) tms tms2;
        iter2 (branch_expr ogname) eqns eqns2
    | CLetTuple (nal,(na,po),b,c), CLetTuple (nal2,(na2,po2),b2,c2) ->
      constr_expr_opt ogname po po2;
      constr_expr ogname b b2;
      constr_expr ogname c c2
    | CIf (c,(na,po),b1,b2), CIf (c2,(na2,po2),b12,b22) ->
      constr_expr ogname c c2;
      constr_expr_opt ogname po po2;
      constr_expr ogname b1 b12;
      constr_expr ogname b2 b22
    | CHole (k,naming,solve), CHole (k2,naming2,solve2) -> ()
    | CPatVar _, CPatVar _ -> ()
    | CEvar (n,l), CEvar (n2,l2) ->
      let oevar = if ogname = "" then Id.to_string n.CAst.v else ogname in
      nevar_to_oevar := CString.Map.add (Id.to_string n2.CAst.v) oevar !nevar_to_oevar;
      iter2  (fun x x2 -> let (_, g) = x and (_, g2) = x2 in constr_expr ogname g g2)  l l2
    | CEvar (n,l), nt' ->
      (* pass down the old goal evar name *)
      match_goals_r (Id.to_string n.CAst.v) nt' nt'
    | CSort s, CSort s2 -> ()
    | CCast (c,k,t), CCast (c2,k2,t2) ->
      constr_expr ogname c c2;
      if not (Glob_ops.cast_kind_eq k k2)
      then raise (Diff_Failure "Unable to match goals between old and new proof states (4)");
      constr_expr ogname t t2
    | CNotation (_,ntn,args), CNotation (_,ntn2,args2) ->
      constr_notation_substitution ogname args args2
    | CGeneralization (b,c), CGeneralization (b2,c2) ->
      constr_expr ogname c c2
    | CPrim p, CPrim p2 -> ()
    | CDelimiters (key,e), CDelimiters (key2,e2) ->
      constr_expr ogname e e2
    | CArray(u,t,def,ty), CArray(u2,t2,def2,ty2) ->
      constr_arr ogname t t2;
      constr_expr ogname def def2;
      constr_expr ogname ty ty2;
    | _, _ -> raise (Diff_Failure "Unable to match goals between old and new proof states (5)")
    end
  in

  (match ot with
  | Some ot -> match_goals_r "" ot nt
  | None -> ());
  !nevar_to_oevar

let get_proof_context (p : Proof.t) =
  let Proof.{goals; sigma} = Proof.data p in
  sigma, Tacmach.pf_env { Evd.it = List.(hd goals); sigma }

let to_constr pf =
  let open CAst in
  let pprf = Proof.partial_proof pf in
  (* pprf generally has only one element, but it may have more in the derive plugin *)
  let t = List.hd pprf in
  let sigma, env = get_proof_context pf in
  let x = Constrextern.extern_constr env sigma t in  (* todo: right options?? *)
  x.v


module GoalMap = Evar.Map

let goal_to_evar g sigma = Id.to_string (Termops.evar_suggested_name (Global.env ()) sigma g)

open Goal.Set

[@@@ocaml.warning "-32"]
let db_goal_map op np ng_to_og =
  let pr_goals title prf =
    Printf.printf "%s: " title;
    let Proof.{goals;sigma} = Proof.data prf in
    List.iter (fun g -> Printf.printf "%d -> %s  " (Evar.repr g) (goal_to_evar g sigma)) goals;
    let gs = diff (Proof.all_goals prf) (List.fold_left (fun s g -> add g s) empty goals) in
    List.iter (fun g -> Printf.printf "%d  " (Evar.repr g)) (elements gs);
  in

  pr_goals "New Goals" np;
  (match op with
  | Some op ->
    pr_goals "\nOld Goals" op
  | None -> ());
  Printf.printf "\nGoal map: ";
  GoalMap.iter (fun ng og -> Printf.printf "%d -> %d  " (Evar.repr ng) (Evar.repr og)) ng_to_og;
  let unmapped = ref (Proof.all_goals np) in
  GoalMap.iter (fun ng _ -> unmapped := Goal.Set.remove ng !unmapped) ng_to_og;
  if Goal.Set.cardinal !unmapped > 0 then begin
    Printf.printf "\nUnmapped goals: ";
    Goal.Set.iter (fun ng -> Printf.printf "%d  " (Evar.repr ng)) !unmapped
  end;
  Printf.printf "\n"
[@@@ocaml.warning "+32"]

(* Create a map from new goals to old goals for proof diff.  New goals
 that are evars not appearing in the proof will not have a mapping.

 It proceeds as follows:
 1. Find the goal ids that were removed from the old proof and that were
 added in the new proof.  If the same goal id is present in both proofs
 then conclude the goal is unchanged (assumption).

 2. The code assumes that proof changes only take the form of replacing
 one or more goal symbols (CEvars) with new terms.  Therefore:
 - if there are no removals, the proofs are the same.
 - if there are removals but no additions, then there are no new goals
   that aren't the same as their associated old goals.  For the both of
   these cases, the map is empty because there are no new goals that differ
   from their old goals
 - if there is only one removal, then any added goals should be mapped to
   the removed goal.
 - if there are more than 2 removals and more than one addition, call
   match_goals to get a map between old and new evar names, then use this
   to create the map from new goal ids to old goal ids.
*)
let make_goal_map_i op np =
  let ng_to_og = ref GoalMap.empty in
  match op with
  | None -> !ng_to_og
  | Some op ->
    let open Goal.Set in
    let ogs = Proof.all_goals op in
    let ngs = Proof.all_goals np in
    let rem_gs = diff ogs ngs in
    let num_rems = cardinal rem_gs in
    let add_gs = diff ngs ogs in
    let num_adds = cardinal add_gs in

    (* add common goals *)
    Goal.Set.iter (fun x -> ng_to_og := GoalMap.add x x !ng_to_og) (inter ogs ngs);

    if num_rems = 0 then
      !ng_to_og (* proofs are the same *)
    else if num_adds = 0 then
      !ng_to_og (* only removals *)
    else if num_rems = 1 then begin
      (* only 1 removal, some additions *)
      let removed_g = List.hd (elements rem_gs) in
      Goal.Set.iter (fun x -> ng_to_og := GoalMap.add x removed_g !ng_to_og) add_gs;
      !ng_to_og
    end else begin
      (* >= 2 removals, >= 1 addition, need to match *)
      let nevar_to_oevar = match_goals (Some (to_constr op)) (to_constr np) in

      let oevar_to_og = ref CString.Map.empty in
      let Proof.{sigma=osigma} = Proof.data op in
      List.iter (fun og -> oevar_to_og := CString.Map.add (goal_to_evar og osigma) og !oevar_to_og)
          (Goal.Set.elements rem_gs);

      let Proof.{sigma=nsigma} = Proof.data np in
      let get_og ng =
        let nevar = goal_to_evar ng nsigma in
        let oevar = CString.Map.find nevar nevar_to_oevar in
        let og = CString.Map.find oevar !oevar_to_og in
        og
      in
      Goal.Set.iter (fun ng ->
          try ng_to_og := GoalMap.add ng (get_og ng) !ng_to_og with Not_found -> ())  add_gs;
      !ng_to_og
    end

let make_goal_map op np =
  let ng_to_og = make_goal_map_i op np in
  ng_to_og

let notify_proof_diff_failure msg =
  Feedback.msg_notice Pp.(str "Unable to compute diffs: " ++ str msg)

let diff_proofs ~diff_opt ?old proof =
  let pp_proof p =
    let sigma, env = Proof.get_proof_context p in
    let pprf = Proof.partial_proof p in
    Pp.prlist_with_sep Pp.fnl (pr_econstr_env env sigma) pprf in
  match diff_opt with
  | DiffOff -> pp_proof proof
  | _ -> begin
      try
        let n_pp = pp_proof proof in
        let o_pp = match old with
          | None -> Pp.mt()
          | Some old -> pp_proof old in
        let show_removed = Some (diff_opt = DiffRemoved) in
        Pp_diff.diff_pp_combined ~tokenize_string ?show_removed o_pp n_pp
      with Pp_diff.Diff_Failure msg ->
        notify_proof_diff_failure msg;
        pp_proof proof
    end
