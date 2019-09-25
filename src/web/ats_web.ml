module Fmt = CCFormat

module Vdom = struct
  include Vdom
  let h2 x = elt "h2" [text x]
  let pre x = elt "pre" [text x]
  let pre_f fmt = Fmt.ksprintf ~f:pre fmt
  let ul l = elt "ul" @@ List.map (fun x -> elt "li" [x]) l
  let button txt msg = input [] ~a:[onclick (fun _ -> msg); type_button; value txt]
  let div_class c x = elt "div" ~a:[class_ c] x

  let details ?short x =
    let open Vdom in
    let l = match short with None -> [x] | Some s -> [elt "summary" [text s]; x] in
    Vdom.(elt "details" l)
end

module Calculus_msg = struct
  type t =
    | M_next
    | M_step
    | M_pick of int
    | M_go_back of int
end

module type APP_CALCULUS = sig
  val name : string

  type msg = Calculus_msg.t
  type model

  val parse : string -> (model, string) result

  val init : model
  val view : model -> msg Vdom.vdom
  val update : model -> msg -> (model, string) result
end

module type CALCULUS = sig
  module A : Ats.ATS.S
  val view : A.State.t -> Calculus_msg.t Vdom.vdom
end

module Make_calculus(C : CALCULUS)
  : APP_CALCULUS
= struct
  open C.A
  open Calculus_msg

  let name = "cdcl"

  type msg = Calculus_msg.t
  type model = {
    parents: State.t list; (* parent states *)
    st: State.t; (* current state *)
    step: (State.t * string) Ats.ATS.step;
  }

  let init =
    let st = State.empty in
    { st; parents=[]; step=Ats.ATS.Done (st, ""); }

  let mk_ parents st =
    { st; parents; step=next st; }

  let parse (s:string) : _ result =
    match CCParse.parse_string State.parse s with
    | Error msg -> Error msg
    | Ok st -> Ok (mk_ [] st)

  let view (m: model) : _ Vdom.vdom =
    let open Vdom in
    let v_actions_pre, v_actions_post = match m.step with
      | Ats.ATS.One _ | Ats.ATS.Done _ | Ats.ATS.Error _ ->
        [button "step" M_step; button "next" M_next], []
      | Ats.ATS.Choice [_] -> [button "step" M_step], []
      | Ats.ATS.Choice l ->
        let choices =
          List.mapi
            (fun i (st,expl) ->
               div_class "ats-choice"
                 [C.view st; button "pick" (M_pick i); text expl])
            l
        in
        [button "step" M_step], choices
    and v_parents =
      let view_parent i st =
        div_class "ats-parent" [
          C.view st;
          button "go back" (M_go_back i);
        ]
      in
      if m.parents=[] then []
       else [
         details ~short:(Printf.sprintf "previous (%d)" (List.length m.parents))
           (div_class "ats-parents" @@ List.mapi view_parent m.parents)]
    in
    div @@ List.flatten [
      [h2 name];
      v_actions_pre;
      [C.view m.st];
      v_actions_post;
      v_parents]

  let update (m:model) (msg:msg) : _ result =
    let {parents; st; step } = m in
    match msg with
    | M_next ->
      begin match step with
        | Ats.ATS.Done (st',_) ->
          Ok (mk_ parents st') (* just go to [st'] *)
        | Ats.ATS.Error msg ->
          Error msg
        | Ats.ATS.One (st',_) | Ats.ATS.Choice [st',_] ->
          Ok (mk_ (st::parents) st')
        | Ats.ATS.Choice _ ->
          Error "need to make a choice"
      end
    | M_step ->
      begin match step with
        | Ats.ATS.Done (st',_) -> Ok (mk_ parents st')
        | Ats.ATS.Error msg -> Error msg
        | Ats.ATS.One (st',_) | Ats.ATS.Choice ((st',_)::_) ->
          Ok (mk_ (st::parents) st') (* make a choice *)
        | Ats.ATS.Choice _ -> assert false
      end
    | M_pick i ->
      begin match step with
        | Ats.ATS.Choice l ->
          begin try Ok (mk_ (st::parents) (fst @@ List.nth l i))
            with _ -> Error "invalid `pick`"
          end
        | _ -> Error "cannot pick a state, not in a choice state"
      end
    | M_go_back i ->
      begin try
          let st = List.nth parents i in
          Ok (mk_ (CCList.drop (i+1) parents) st)
        with _ -> Error "invalid index in parents"
      end
end

module CDCL = Make_calculus(struct
    module A = Ats.ATS.Make(Ats.CDCL.A)
    open Ats.CDCL
    open Calculus_msg

    let view (st:State.t) : Calculus_msg.t Vdom.vdom =
      let open Vdom in
      let status, trail, cs = State.view st in
      div_class "ats-state" [
        pre (Fmt.sprintf "status: %a" State.pp_status status);
        details ~short:(Fmt.sprintf "trail (%d elts)" (Trail.length trail)) (
          Trail.to_iter trail
          |> Iter.map
            (fun elt -> pre (Fmt.to_string Trail.pp_trail_elt elt))
          |> Iter.to_list |> div_class "ats-trail"
        );
        details ~short:(Fmt.sprintf "clauses (%d)" (List.length cs)) (
          List.map (fun c -> pre_f "%a" Clause.pp c) cs |> div_class "ats-clauses"
        );
      ]
  end)

(* TODO
module MCSAT = Make_calculus(Ats.ATS.Make(Ats.MCSAT.A))
   *)

module App = struct
  open Vdom

  type msg =
    | M_load of string
    | M_set_parse of string
    | M_parse
    | M_calculus of Calculus_msg.t

  type logic_model =
    | LM : {
        app: (module APP_CALCULUS with type model = 'm);
        model: 'm;
      } -> logic_model
      
  type model = {
    error: string option;
    parse: string;
    lm: logic_model;
  }

  let all = ["cdcl"; "mcsat"]
  let init_ s : logic_model =
    match s with
    | "cdcl" -> LM { app=(module CDCL); model=CDCL.init; }
    | "mcsat" ->
      assert false (* TODO *)
    | s -> failwith @@ "unknown system " ^ s

  let init : model =
    { error=None; parse=""; lm=init_ "cdcl";
    }

  let update (m:model) (msg:msg) =
    match msg, m with
    | M_load s, _ -> {error=None; lm=init_ s; parse=""}
    | M_set_parse s, _ -> {m with parse=s}
    | M_parse, {parse=s; lm; _} ->
      let lm' = match lm with
        | LM {app=(module App) as app; _} ->
          App.parse s |> CCResult.map (fun m -> LM {app; model=m})
      in
      begin match lm' with
        | Ok lm' -> {m with error=None; lm=lm'}
        | Error msg ->
          {m with error=Some msg}
      end
    | M_calculus msg, {lm=LM {app=(module App) as app; model};_} ->
      begin match App.update model msg with
        | Ok lm -> {m with error=None; lm=LM {app; model=lm}}
        | Error msg -> {m with error=Some msg}
      end
      (* TODO
    | M_cdcl _, _ -> {m with error=Some "invalid message for CDCL";}
         *)

  let view (m:model) =
    let {error; parse; lm} = m in
    let v_error = match error with
      | None -> []
      | Some s -> [div ~a:[style "color" "red"] [text s]]
    and v_load = [ 
      ul @@ List.map (fun s -> button ("load " ^ s) (M_load s)) all;
    ]
    and v_parse = [
      div [
        input [] ~a:[type_ "text"; value parse; oninput (fun s -> M_set_parse s)];
        button "parse" M_parse;
      ]
    ]
    and v_lm = match lm with
      | LM {app=(module App); model} ->
        [App.view model |> map (fun x -> M_calculus x)]
    in
    div @@ List.flatten [v_error; v_load; v_parse; v_lm]

  let app = Vdom.simple_app ~init ~update ~view ()
end

open Js_browser

let run () = Vdom_blit.run App.app |> Vdom_blit.dom |> Element.append_child (Document.body document)
let () = Window.set_onload window run