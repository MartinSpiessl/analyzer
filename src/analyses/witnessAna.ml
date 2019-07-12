(** An analysis specification for witnesses. *)

open Prelude.Ana
open Analyses

module PrintableVar =
struct
  include Var
  let to_yojson = MyCFG.node_to_yojson

  let isSimple _ = true
  let pretty_f _ = pretty
  let pretty_diff () (x,y) = dprintf "Unsupported"
  (* let short n x = Pretty.sprint n (pretty () x) *)
  (* let short _ x = var_id x *)
  let short _ x =
    let open MyCFG in
    match x with
    | Statement stmt  -> string_of_int stmt.sid
    | Function f      -> "return of " ^ f.vname ^ "()"
    | FunctionEntry f -> f.vname ^ "()"
  let toXML x =
    let text = short 100 x in
    Xml.Element ("value", [], [Xml.Element ("data", [], [Xml.PCData text])])
  let toXML_f _ = toXML
  let printXml f x =
    BatPrintf.fprintf f "%s" (Xml.to_string (toXML x))
  let name () = "var"
  let invariant _ _ = Invariant.none
end

module FlatBot (Base: Printable.S) = Lattice.LiftBot (Lattice.Fake (Base))

module Spec : Analyses.Spec =
struct
  include Analyses.DefaultSpec

  let name = "witness"

  module V = PrintableVar
  module S = SetDomain.Make (V)
  module F = FlatBot (V)

  module D = Lattice.Prod (S) (F)
  module G = Lattice.Unit
  module C = D

  let set_of_flat (x:F.t): S.t = match x with
    | `Lifted x -> S.singleton x
    | `Bot -> S.bot ()

  let step (from:D.t) (to_node:V.t): D.t =
    let prev = set_of_flat (snd from) in
    (prev, F.lift to_node)

  let step_ctx ctx = step ctx.local ctx.node

  (* transfer functions *)
  let assign ctx (lval:lval) (rval:exp) : D.t =
    step_ctx ctx

  let branch ctx (exp:exp) (tv:bool) : D.t =
    step_ctx ctx

  let body ctx (f:fundec) : D.t =
    step_ctx ctx

  let return ctx (exp:exp option) (f:fundec) : D.t =
    step_ctx ctx

  let enter ctx (lval: lval option) (f:varinfo) (args:exp list) : (D.t * D.t) list =
    [ctx.local, step ctx.local (FunctionEntry f)]

  let combine ctx (lval:lval option) fexp (f:varinfo) (args:exp list) (au:D.t) : D.t =
    step au ctx.node

  let special ctx (lval: lval option) (f:varinfo) (arglist:exp list) : D.t =
    step_ctx ctx

  let startstate v = D.bot ()
  let otherstate v = D.bot ()
  let exitstate  v = D.bot ()
end

module WitnessLifter (S:Spec): Spec =
struct
  module V = PrintableVar

  (* module VS = SetDomain.Make (V)
     module VF = FlatBot (V)
     module W = Lattice.Prod (VS) (VF) *)
  module VS = SetDomain.ToppedSet (V) (struct let topname = "VS top" end)
  module VF = Lattice.Flat (V) (struct let bot_name = "VF bot" let top_name = "VF top" end)
  module W = Lattice.Prod (VS) (VF)

  module D =
  struct
    include Lattice.Prod (S.D) (W)

    (* alternative to using strict *)
    let is_bot (d, w) = S.D.is_bot d

    let printXml f (d, w) =
      BatPrintf.fprintf f "%a<path><analysis name=\"witness\">%a</analysis></path>" S.D.printXml d W.printXml w
  end
  module G = S.G
  module C = S.C
  (* module C =
     struct
       include Printable.Prod (S.C) (W)

       let printXml f (d, w) =
         BatPrintf.fprintf f "%a<path><analysis name=\"witness\">%a</analysis></path>" S.C.printXml d W.printXml w
     end *)

  let set_of_flat (x:VF.t): VS.t = match x with
    | `Lifted x -> VS.singleton x
    | `Bot -> VS.bot ()
    | `Top -> VS.top ()

  let step (from:W.t) (to_node:V.t): W.t =
    let prev = set_of_flat (snd from) in
    (* ignore (Pretty.printf "from: %a, prev: %a -> to_node: %a\n" W.pretty from VS.pretty prev V.pretty to_node); *)
    (prev, `Lifted to_node)

  let step_ctx ctx = step (snd ctx.local) ctx.node

  (* let strict (d, w) = if S.D.is_bot d then D.bot () else (d, w) *)
  let strict (d, w) = (d, w) (* D.is_bot redefined *)

  let name = S.name ^ " witnessed"

  let init = S.init
  let finalize = S.finalize

  let startstate v = (S.startstate v, W.bot ())
  let morphstate v (d, w) = (S.morphstate v d, w)
  let exitstate v = (S.exitstate v, W.bot ())
  let otherstate v = (S.otherstate v, W.bot ())

  let should_join (x, _) (y, _) = S.should_join x y
  let val_of c = (S.val_of c, W.bot ())
  (* let val_of ((c, w):C.t): D.t = (S.val_of c, w) *)
  let context (d, _) = S.context d
  (* let context ((d, w):D.t): C.t = (S.context d, w) *)
  let call_descr = S.call_descr
  (* let call_descr f ((c, w):C.t) = S.call_descr f c *)

  let unlift_ctx (ctx:(D.t, 'g) Analyses.ctx) =
    let w = snd ctx.local in
    { ctx with
      local = fst ctx.local;
      spawn = (fun v d -> ctx.spawn v (strict (d, w)));
      split = (fun d e tv -> ctx.split (strict (d, w)) e tv)
    }
  let part_access ctx = S.part_access (unlift_ctx ctx)

  let sync ctx =
    let (d, l) = S.sync (unlift_ctx ctx) in
    (* let w = step_ctx ctx in *)
    let w = snd ctx.local in
    (strict (d, w), l)

  let query ctx q = S.query (unlift_ctx ctx) q

  let assign ctx lv e =
    let d = S.assign (unlift_ctx ctx) lv e in
    let w = step_ctx ctx in
    strict (d, w)

  let branch ctx e tv =
    let d = S.branch (unlift_ctx ctx) e tv in
    let w = step_ctx ctx in
    strict (d, w)

  let body ctx f =
    let d = S.body (unlift_ctx ctx) f in
    let w = step_ctx ctx in
    strict (d, w)

  let return ctx r f =
    let d = S.return (unlift_ctx ctx) r f in
    let w = step_ctx ctx in
    strict (d, w)

  let intrpt ctx =
    let d = S.intrpt (unlift_ctx ctx) in
    (* let w = step_ctx ctx in *)
    let w = snd ctx.local in
    strict (d, w)

  let special ctx r f args =
    let d = S.special (unlift_ctx ctx) r f args in
    let w = step_ctx ctx in
    strict (d, w)

  let enter ctx r f args =
    let ddl = S.enter (unlift_ctx ctx) r f args in
    let w = snd ctx.local in
    let w' = step w (FunctionEntry f) in
    List.map (fun (d1, d2) -> (strict (d1, w), strict (d2, w'))) ddl

  let combine ctx r fe f args (d', w') =
    let d = S.combine (unlift_ctx ctx) r fe f args d' in
    let w = step w' ctx.node in
    strict (d, w)
end

let _ =
  MCP.register_analysis (module Spec : Spec)
