(** Tracking of priorities an partition modes. *)

open Batteries
open Cil
open Pretty
open Analyses

(* Information for one task *)
(* Process ID *)
module Pid = IntDomain.Flattened
(* Priority *)
module Pri = IntDomain.Reverse (IntDomain.Lifted) (* TODO reverse? *)
(* Period *)
module Per = IntDomain.Flattened
(* Capacity *)
module Cap = IntDomain.Flattened

(* Information for all tasks *)
(* Partition mode *)
module Pmo = IntDomain.Flattened
(* Preemption lock *)
module PrE = IntDomain.Flattened

module Spec : Analyses.Spec =
struct
  include Analyses.DefaultSpec

  let name = "arinc"
  module D =
  struct
    module Intra = Lattice.Prod3 (Pri) (Per) (Cap)
    module Inter = Lattice.Prod3 (Pmo) (PrE) (Pid) (* Pid should be in Intra, but there is no Prod 4 :/ *)
    include Lattice.Prod (Intra) (Inter)
    let toXML_f sf ((pri,per,cap), (pmo,pre,pid)) =
      let replace_top name = function
          | Xml.Element (node, [text, n], elems) -> Xml.Element (node, [text, name ^ n], elems)
          | x -> x
      in
      let elems = [ replace_top "Priority: "   @@ Pri.toXML  pri
                  ; replace_top "Period: "  @@ Per.toXML per
                  ; replace_top "Capacity: "  @@ Cap.toXML cap
                  ; replace_top "Partition mode: "  @@ Pmo.toXML pmo
                  ; replace_top "Preemption lock: " @@ PrE.toXML  pre ] in
      Xml.Element ("Node", ["text", "ARINC state"], elems)

    let toXML s  = toXML_f short s

    let pid f ((pri,per,cap), (pmo,pre,pid)) = ((pri,per,cap), (pmo,pre,f pid))
    let pri f ((pri,per,cap), (pmo,pre,pid)) = ((f pri,per,cap), (pmo,pre,pid))
    let per f ((pri,per,cap), (pmo,pre,pid)) = ((pri,f per,cap), (pmo,pre,pid))
    let cap f ((pri,per,cap), (pmo,pre,pid)) = ((pri,per,f cap), (pmo,pre,pid))
    let pmo f ((pri,per,cap), (pmo,pre,pid)) = ((pri,per,cap), (f pmo,pre,pid))
    let pre f ((pri,per,cap), (pmo,pre,pid)) = ((pri,per,cap), (pmo,f pre,pid))
  end
  module G = IntDomain.Booleans
  module C = D

  let is_single ctx =
    let fl : BaseDomain.Flag.t = snd (Obj.obj (List.assoc "base" ctx.presub)) in
    not (BaseDomain.Flag.is_multi fl)

  let part_mode_var = makeGlobalVar "__GOBLINT_ARINC_MUTLI_THREADED" voidPtrType

  (* transfer functions *)
  let assign ctx (lval:lval) (rval:exp) : D.t =
    ctx.local

  let branch ctx (exp:exp) (tv:bool) : D.t =
    ctx.local

  let body ctx (f:fundec) : D.t =
    if not (is_single ctx || !Goblintutil.global_initialization || ctx.global part_mode_var) then raise Analyses.Deadcode;
    ctx.local

  let return ctx (exp:exp option) (f:fundec) : D.t =
    ctx.local

  let enter ctx (lval: lval option) (f:varinfo) (args:exp list) : (D.t * D.t) list =
    [ctx.local, ctx.local]

  let combine ctx (lval:lval option) fexp (f:varinfo) (args:exp list) (au:D.t) : D.t =
    au

  let sprint f x = Pretty.sprint 80 (f () x)
  let string_of_partition_mode = function
    | 0L -> "IDLE"
    | 1L -> "COLD_START"
    | 2L -> "WARM_START"
    | 3L -> "NORMAL"
    | _  -> "UNKNOWN!"
  let string_of_queuing_discipline = function
    | 0L -> "FIFO"
    | 1L -> "PRIO"
    | _  -> "UNKNOWN!"
  let mode_is_init  i = match Pmo.to_int i with Some 1L | Some 2L -> true | _ -> false
  let mode_is_multi i = Pmo.to_int i = Some 3L
  let infinity = 4294967295L (* time value used for infinity *)

  type id = int64
  type time = int64 (* Maybe use Nativeint which is the same as C long. OCaml int is just 31 or 63 bits wide! *)
  type action =
    | LockPreemption | UnlockPreemption | SetPartitionMode of int64
    | CreateProcess of id * varinfo * int64 * time * time | CreateErrorHandler of id | Start of id | Stop of id | Suspend of id | Resume of id
    | CreateBlackboard of id | DisplayBlackboard of id | ReadBlackboard of id * time | ClearBlackboard of id
    | CreateSemaphore of id * int64 * int64 * int64 | WaitSemaphore of id | SignalSemaphore of id
    | CreateEvent of id | WaitEvent of id * time | SetEvent of id | ResetEvent of id
    | TimedWait of time | PeriodicWait
  let actions = Hashtbl.create 123 (* use BatMultiPMap later? *)
  let get_actions pid : action list =
    (* Hashtbl.find_default actions pid [] |> List.unique *)
    Hashtbl.find_all actions pid (* current binding first, then previous bindings *)
    |> List.unique |> List.rev
  let add_action pid action =
    (* Hashtbl.modify_def [] pid (List.cons action) actions *)
    Hashtbl.add actions pid action (* old binding is just hidden *)

  (* lookup/generate id from resource type and name (needed for LAP_Se_GetXId functions, specified by LAP_Se_CreateX functions during init) *)
  type resource = Process | Semaphore | Event | Logbook | SamplingPort | QueuingPort | Buffer | Blackboard
  let resources = Hashtbl.create 123
  let get_id (resource:resource*string) : int64 =
    try Hashtbl.find resources resource
    with Not_found ->
      let ids = Hashtbl.values resources in
      let id = if Enum.is_empty ids then 1L else Int64.succ (Enum.arg_max identity ids) in
      Hashtbl.add resources resource id;
      id
  let get_by_id (id:int64) : (resource*string) option =
    Hashtbl.filter ((=) id) resources |> Hashtbl.keys |> Enum.get
  (* map function to process name in order to get pid (1:1 relation?) *)
  (* TODO maybe there can be multiple processes for the same function -> save pid in D! *)
  let funs = Hashtbl.create 123
  let add_fun (processname:string) (f:varinfo) =
    Hashtbl.add funs processname f
  let fun_from_name (processname:string) : varinfo option =
    Hashtbl.find_option funs processname


  let print_actions () =
(*     let str_resource_type = function
      | Process -> "Process"
      | Semaphore -> "Semaphore"
      | Event -> "Event"
      | Logbook -> "Logbook"
      | SamplingPort -> "SamplingPort"
      | QueuingPort -> "QueuingPort"
      | Buffer -> "Buffer"
      | Blackboard -> "Blackboard"
    in *)
    let str_i64 id = string_of_int (i64_to_int id) in
    let str_resource id =
      let name = match get_by_id id with
        | Some (Process, name) ->
            let fname = match fun_from_name name with
              | Some v -> v.vname
              | None -> "??"
            in
            name^"/"^fname
        | Some (resource_type, name) ->
            name
        | None when id = 0L -> "mainfun/["^String.concat ", " (List.map Json.string (GobConfig.get_list "mainfun"))^"]"
        | None -> "Unknown resource"
      in name^"#"^str_i64 id
    in
    let str_time t = if t = infinity then "∞" else str_i64 t^"ns" in
    let str_action pid = function
      | LockPreemption -> "LockPreemption"
      | UnlockPreemption -> "UnlockPreemption"
      | SetPartitionMode i -> "SetPartitionMode "^string_of_partition_mode i
      | CreateProcess (id, f, prio, period, capacity) ->
          "CreateProcess "^str_resource id^" (fun "^f.vname^", prio "^str_i64 prio^", period "^str_time period^", capacity "^str_time capacity^")"
      | CreateErrorHandler id -> "CreateErrorHandler "^str_resource id
      | Start id -> "Start "^str_resource id
      | Stop id when id=pid -> "StopSelf"
      | Stop id -> "Stop "^str_resource id
      | Suspend id when id=pid -> "SuspendSelf"
      | Suspend id -> "Suspend "^str_resource id
      | Resume id -> "Resume "^str_resource id
      | CreateBlackboard id -> "CreateBlackboard "^str_resource id
      | DisplayBlackboard id -> "DisplayBlackboard "^str_resource id
      | ReadBlackboard (id, timeout) -> "ReadBlackboard "^str_resource id^" (timeout "^str_time timeout^")"
      | ClearBlackboard id -> "ClearBlackboard "^str_resource id
      | CreateSemaphore (id, cur, max, queuing) ->
          "CreateSemaphore "^str_resource id^" ("^str_i64 cur^"/"^str_i64 max^", "^string_of_queuing_discipline queuing^")"
      | WaitSemaphore id -> "WaitSemaphore "^str_resource id
      | SignalSemaphore id -> "SignalSemaphore "^str_resource id
      | CreateEvent id -> "CreateEvent "^str_resource id
      | WaitEvent (id, timeout) -> "WaitEvent "^str_resource id^" (timeout "^str_time timeout^")"
      | SetEvent id -> "SetEvent "^str_resource id
      | ResetEvent id -> "ResetEvent "^str_resource id
      | TimedWait t -> "TimedWait "^str_time t
      | PeriodicWait -> "PeriodicWait"
    in
    let print_process pid =
      let xs = List.map (str_action pid) (get_actions pid) in
      M.debug @@ str_resource pid^" ->\n\t"^String.concat ",\n\t" xs
    in
    Hashtbl.keys actions |> Enum.iter print_process
  let finalize () = print_actions ()


  let special ctx (lval: lval option) (f:varinfo) (arglist:exp list) : D.t =
    let is_arinc_fun = startsWith "LAP_Se_" f.vname in
    let is_creating_fun = startsWith "LAP_Se_Create" f.vname in
    let is_error_handler = false in (* TODO *)
    if M.tracing && is_arinc_fun then (
      let args_str = String.concat ", " (List.map (sprint d_exp) arglist) in
      (* M.tracel "arinc" "found %s(%s)\n" f.vname args_str *)
      M.debug_each @@ "found "^f.vname^"("^args_str^")"
    );
    let todo () = if false then failwith @@ f.vname^": Not implemented yet!" else ctx.local in
    let curfun = MyCFG.getFun (Option.get !MyCFG.current_node) in (* current_node should always be set here *)
    (* M.debug_each @@ "Inside function "^curfun.svar.vname; *)
    let ((pri,per,cap), (pmo,pre,pid)) = ctx.local in
    let curpid = match Pid.to_int pid with Some i -> i | None -> failwith @@ "special: Pid.to_int = None inside function "^curfun.svar.vname in
    let eval_int exp =
      match ctx.ask (Queries.EvalInt exp) with
      | `Int i -> i
      | _ -> failwith @@ "Could not evaluate int-argument "^sprint d_plainexp exp^" in "^f.vname
    in
    let eval_str exp =
      match ctx.ask (Queries.EvalStr exp) with
      | `Str s -> s
      | _ -> failwith @@ "Could not evaluate string-argument "^sprint d_plainexp exp^" in "^f.vname
    in
    let assign_id exp id =
      match exp with
      (* call assign for all analyses (we only need base)! *)
      | AddrOf lval -> ctx.assign ~name:"base" lval (kinteger64 ILong id); ctx.local
      | _ -> failwith @@ "Could not assign id. Expected &id. Found "^sprint d_exp exp
    in
    let assign_id_by_name resource_type name id =
      assign_id id (get_id (resource_type, eval_str name))
    in
    let arglist = List.map (stripCasts%(constFold false)) arglist in
    match f.vname, arglist with
      | _ when is_arinc_fun && is_creating_fun && not(mode_is_init pmo) ->
          failwith @@ f.vname^" is only allowed in partition mode COLD_START or WARM_START"
    (* Preemption *)
      | "LAP_Se_LockPreemption", _ when not is_error_handler ->
          add_action curpid LockPreemption;
          D.pre (PrE.add (PrE.of_int 1L)) ctx.local
      | "LAP_Se_UnlockPreemption", _ when not is_error_handler ->
          add_action curpid UnlockPreemption;
          D.pre (PrE.sub (PrE.of_int 1L)) ctx.local
    (* Partition *)
      | "LAP_Se_SetPartitionMode", [mode; r] -> begin
          match ctx.ask (Queries.EvalInt mode) with
          | `Int i ->
              if M.tracing then M.tracel "arinc" "setting partition mode to %Ld (%s)\n" i (string_of_partition_mode i);
              if mode_is_multi (Pmo.of_int i) then ctx.sideg part_mode_var true;
              add_action curpid (SetPartitionMode i);
              D.pmo (const @@ Pmo.of_int i) ctx.local
          | `Bot -> D.bot ()
          | _ -> ctx.sideg part_mode_var true; D.top ()
          end
      | "LAP_Se_GetPartitionStatus", [status; r] -> todo () (* != mode *)
      | "LAP_Se_GetPartitionStartCondition", _ -> todo ()
    (* Processes *)
      | "F59", [dst; src] ->
          (* M.debug @@ "strcpy("^sprint d_plainexp dst^", "^sprint d_plainexp src^")"; *)
          (* let exp = mkAddrOrStartOf (mkMem ~addr:dst ~off:NoOffset) in *)
          let lval = match dst with
            | Lval lval
            | StartOf lval -> lval
            | AddrOf lval -> lval
            | _ -> failwith @@ "F59/strcpy expects first argument to be some Lval, but got "^sprint d_plainexp dst
          in
          let exp = mkAddrOf lval in
          begin match ctx.ask (Queries.MayPointTo exp) with
          | `LvalSet ls when not (Queries.LS.is_top ls) && Queries.LS.cardinal ls = 1 ->
              let v, offs = Queries.LS.choose ls in
              let ciloffs = Lval.CilLval.to_ciloffs offs in
              let lval = Var v, ciloffs in
              (* ignore @@ printf "dst: %a, MayPointTo: %a" d_plainexp dst d_plainlval lval; *)
              ctx.assign ~name:"base" lval src;
              ctx.local
          | _ -> failwith @@ "F59/strcpy could not query MayPointTo "^sprint d_plainexp exp
          end
      | "LAP_Se_CreateProcess", [AddrOf attr; pid; r] ->
          let cm = match unrollType (typeOfLval attr) with
            | TComp (c,_) -> c
            | _ -> failwith "type-error: first argument of LAP_Se_CreateProcess not a struct."
          in
          let struct_fail () = failwith @@ "LAP_Se_CreateProcess: problem with first argument (struct PROCESS_ATTRIBUTE_TYPE): needs fields NAME, ENTRY_POINT, BASE_PRIORITY, PERIOD, TIME_CAPACITY\nRunning scrambled: "^string_of_bool Goblintutil.scrambled in
          let field ofs =
            try Lval (addOffsetLval (Field (getCompField cm ofs, NoOffset)) attr)
            with Not_found -> struct_fail ()
          in
          let name = ctx.ask (Queries.EvalStr (field Goblintutil.arinc_name)) in
          let entry_point = ctx.ask (Queries.ReachableFrom (AddrOf attr)) in
          let pri  = ctx.ask (Queries.EvalInt (field Goblintutil.arinc_base_priority)) in
          let per  = ctx.ask (Queries.EvalInt (field Goblintutil.arinc_period)) in
          let cap  = ctx.ask (Queries.EvalInt (field Goblintutil.arinc_time_capacity)) in
          begin match name, entry_point, pri, per, cap with
          | `Str name, `LvalSet ls, `Int pri, `Int per, `Int cap when not (Queries.LS.is_top ls)
            && not (Queries.LS.mem (dummyFunDec.svar,`NoOffset) ls) ->
              let funs = Queries.LS.filter (fun l -> isFunctionType (fst l).vtype) ls in
              if M.tracing then M.tracel "arinc" "starting a thread %a with priority '%Ld' \n" Queries.LS.pretty funs pri;
              let pid' = get_id (Process, name) in (* better to keep that in D (would also supersede mapping from f to name) *)
              let spawn f =
                add_fun name f;
                add_action curpid (CreateProcess (pid', f, pri, per, cap));
                ctx.spawn f ((Pri.of_int pri, Per.of_int per, Cap.of_int cap), (Pmo.of_int 3L, PrE.of_int 0L, Pid.of_int pid'))  (* spawn should happen only when scheduled (after Start() and set mode NORMAL) *)
              in
              Queries.LS.iter (spawn%fst) funs;
              assign_id pid pid'
          (* TODO when is `Bot returned? *)
          (* | `Bot, _ | _, `Bot -> D.bot () *)
          | _ -> struct_fail ()
          end
      | "LAP_Se_GetProcessId", [name; pid; r] ->
          assign_id_by_name Process name pid
      | "LAP_Se_GetProcessStatus", [pid; status; r] -> todo ()
      | "LAP_Se_GetMyId", [pid; r] ->
          assign_id pid curpid
      | "LAP_Se_Start", [pid; r] ->
          (* at least one process should be started in main *)
          let pid = eval_int pid in
          add_action curpid (Start pid);
          ctx.local
      | "LAP_Se_DelayedStart", [pid; delay; r] -> todo ()
      | "LAP_Se_Stop", [pid; r] ->
          let pid = eval_int pid in
          add_action curpid (Stop pid);
          ctx.local
      | "LAP_Se_StopSelf", [] ->
          add_action curpid (Stop curpid);
          ctx.local
      | "LAP_Se_Suspend", [pid; r] ->
          let pid = eval_int pid in
          add_action curpid (Suspend pid);
          ctx.local
      | "LAP_Se_SuspendSelf", [timeout; r] -> (* TODO timeout *)
          add_action curpid (Suspend curpid);
          ctx.local
      | "LAP_Se_Resume", [pid; r] ->
          let pid = eval_int pid in
          add_action curpid (Resume pid);
          ctx.local
    (* Logbook *)
      | "LAP_Se_CreateLogBook", [name; max_size; max_logged; max_in_progress; lbid; r] -> todo ()
      | "LAP_Se_ReadLogBook", _ -> todo ()
      | "LAP_Se_WriteLogBook", _ -> todo ()
      | "LAP_Se_ClearLogBook", _ -> todo ()
      | "LAP_Se_GetLogBookId", _ -> todo ()
      | "LAP_Se_GetLogBookStatus", _ -> todo ()
    (* SamplingPort *)
      | "LAP_Se_CreateSamplingPort", [name; max_size; dir; period; spid; r] -> todo ()
      | "LAP_Se_WriteSamplingMessage", _ -> todo ()
      | "LAP_Se_ReadSamplingMessage", _ -> todo ()
      | "LAP_Se_GetSamplingPortId", _ -> todo ()
      | "LAP_Se_GetSamplingPortStatus", _ -> todo ()
    (* QueuingPort *)
      | "LAP_Se_CreateQueuingPort", [name; max_size; max_range; dir; queuing; qpid; r] -> todo ()
      | "LAP_Se_SendQueuingMessage", _ -> todo ()
      | "LAP_Se_ReceiveQueuingMessage", _ -> todo ()
      | "LAP_Se_GetQueuingPortId", _ -> todo ()
      | "LAP_Se_GetQueuingPortStatus", _ -> todo ()
    (* Buffer *)
      | "LAP_Se_CreateBuffer", [name; max_size; max_range; queuing; buid; r] -> todo ()
      | "LAP_Se_SendBuffer", _ -> todo ()
      | "LAP_Se_ReceiveBuffer", _ -> todo ()
      | "LAP_Se_GetBufferId", _ -> todo ()
      | "LAP_Se_GetBufferStatus", _ -> todo ()
    (* Blackboard *)
      | "LAP_Se_CreateBlackboard", [name; max_size; bbid; r] ->
          let bbid' = get_id (Blackboard, eval_str name) in
          add_action curpid (CreateBlackboard bbid');
          assign_id bbid bbid'
      | "LAP_Se_DisplayBlackboard", [bbid; msg_addr; len; r] ->
          add_action curpid (DisplayBlackboard (eval_int bbid));
          ctx.local
      | "LAP_Se_ReadBlackboard", [bbid; timeout; msg_addr; len; r] ->
          add_action curpid (ReadBlackboard (eval_int bbid, eval_int timeout));
          ctx.local
      | "LAP_Se_ClearBlackboard", [bbid; r] ->
          add_action curpid (ClearBlackboard (eval_int bbid));
          ctx.local
      | "LAP_Se_GetBlackboardId", [name; bbid; r] ->
          assign_id_by_name Blackboard name bbid
      | "LAP_Se_GetBlackboardStatus", _ -> todo ()
    (* Semaphores *)
      | "LAP_Se_CreateSemaphore", [name; cur; max; queuing; sid; r] ->
          (* create resource for name *)
          let sid' = get_id (Semaphore, eval_str name) in
          add_action curpid (CreateSemaphore (sid', eval_int cur, eval_int max, eval_int queuing));
          assign_id sid sid'
      | "LAP_Se_WaitSemaphore", [sid; timeout; r] -> (* TODO timeout *)
          let sid = eval_int sid in
          add_action curpid (WaitSemaphore sid);
          ctx.local
      | "LAP_Se_SignalSemaphore", [sid; r] ->
          let sid = eval_int sid in
          add_action curpid (SignalSemaphore sid);
          ctx.local
      | "LAP_Se_GetSemaphoreId", [name; sid; r] ->
          assign_id_by_name Semaphore name sid
      | "LAP_Se_GetSemaphoreStatus", [sid; status; r] -> todo ()
    (* Events (down after create/reset, up after set) *)
      | "LAP_Se_CreateEvent", [name; eid; r] ->
          let eid' = get_id (Event, eval_str name) in
          add_action curpid (CreateEvent eid');
          assign_id eid  eid'
      | "LAP_Se_SetEvent", [eid; r] ->
          let eid = eval_int eid in
          add_action curpid (SetEvent eid);
          ctx.local
      | "LAP_Se_ResetEvent", [eid; r] ->
          let eid = eval_int eid in
          add_action curpid (ResetEvent eid);
          ctx.local
      | "LAP_Se_WaitEvent", [eid; timeout; r] -> (* TODO timeout *)
          let eid = eval_int eid in
          add_action curpid (WaitEvent (eid, eval_int timeout));
          ctx.local
      | "LAP_Se_GetEventId", [name; eid; r] ->
          assign_id_by_name Event name eid
      | "LAP_Se_GetEventStatus", [eid; status; r] -> todo ()
    (* Time *)
      | "LAP_Se_GetTime", [time; r] -> todo ()
      | "LAP_Se_TimedWait", [delay; r] ->
          add_action curpid (TimedWait (eval_int delay));
          ctx.local
      | "LAP_Se_PeriodicWait", [r] ->
          add_action curpid PeriodicWait;
          ctx.local
    (* Errors *)
      | "LAP_Se_CreateErrorHandler", [entry_point; stack_size; r] ->
          let name = "ErrorHandler" in
          let pid = get_id (Process, name) in
          add_action curpid (CreateErrorHandler pid);
          begin match ctx.ask (Queries.ReachableFrom (entry_point)) with
          | `LvalSet ls when not (Queries.LS.is_top ls) && not (Queries.LS.mem (dummyFunDec.svar,`NoOffset) ls) ->
              let funs = Queries.LS.filter (fun l -> isFunctionType (fst l).vtype) ls in
              let spawn f =
                add_fun name f;
                ctx.spawn f ((Pri.of_int infinity, Per.of_int infinity, Cap.of_int infinity), (Pmo.of_int 3L, PrE.of_int 0L, Pid.of_int pid))
              in
              Queries.LS.iter (spawn%fst) funs
          | _ -> failwith @@ "CreateErrorHandler: could not find out which functions are reachable from first argument!"
          end;
          ctx.local
      | "LAP_Se_GetErrorStatus", [status; r] -> todo ()
      | "LAP_Se_RaiseApplicationError", [error_code; message_addr; length; r] -> todo ()
    (* Not allowed: change configured schedule *)
      | "LAP_Se_SetPriority", [pid; prio; r] -> todo ()
      | "LAP_Se_Replenish", [budget; r] -> todo () (* name used in docs *)
      | "LAP_Se_ReplenishAperiodic", [budget; r] -> todo () (* name used in stdapi.c *)
      | _ when is_arinc_fun -> failwith @@ "Function "^f.vname^" not handled!"
      | _ -> ctx.local

  let query ctx (q:Queries.t) : Queries.Result.t =
    let ((pri,per,cap), (pmo,pre,pid)) = ctx.local in
    match q with
      | Queries.Priority _ ->
          if Pri.is_int pri then
            `Int (Option.get @@ Pri.to_int pri)
          else if Pri.is_top pri then `Top else `Bot
      | Queries.IsPrivate _ ->
          `Bool ((PrE.to_int pre <> Some 0L && PrE.to_int pre <> None) || Pmo.to_int pmo = Some 1L || Pmo.to_int pmo = Some 2L)
      | _ -> Queries.Result.top ()

  let startstate v = ((Pri.top (), Per.top (), Cap.top ()), (Pmo.of_int 1L, PrE.of_int 0L, Pid.of_int 0L))
  let otherstate v = D.top ()
  let exitstate  v = D.top ()
end

let _ =
  MCP.register_analysis ~dep:["base"] (module Spec : Spec)
