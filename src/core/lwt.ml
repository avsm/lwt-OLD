(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt
 * Copyright (C) 2005-2008 J�r�me Vouillon
 * Laboratoire PPS - CNRS Universit� Paris Diderot
 *                    2009 J�r�mie Dimino
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

(* +-----------------------------------------------------------------+
   | Types                                                           |
   +-----------------------------------------------------------------+ *)

exception Canceled

module Int_map = Map.Make(struct type t = int let compare = compare end)

type data = (unit -> unit) Int_map.t
  (* Type of data carried by threads *)

type +'a t
type -'a u

type 'a thread_state =
  | Return of 'a
      (* [Return v] a terminated thread which has successfully
         terminated with the value [v] *)
  | Fail of exn
      (* [Fail exn] a terminated thread which has failed with the
         exception [exn] *)
  | Sleep of 'a sleeper
      (* [Sleep sleeper] is a sleeping thread *)
  | Repr of 'a thread_repr
      (* [Repr t] a thread which behaves the same as [t] *)

and 'a thread_repr = {
  mutable state : 'a thread_state;
  (* The state of the thread *)

  data : data;
  (* Data carried by this thread *)
}

and 'a sleeper = {
  cancel : (unit -> unit) ref;
  (* The cancel function of the thread *)
  mutable waiters : 'a waiter_set;
  (* All thunk functions *)
  mutable removed : int;
  (* Number of waiter that have been disabled. When this number
     reaches [max_removed], they are effectively removed from
     [waiters]. *)
}

(* Type of set of waiters: *)
and 'a waiter_set =
  | Empty
  | Removable of data * ('a thread_state -> unit) option ref
  | Immutable of data * ('a thread_state -> unit)
  | Append of 'a waiter_set * 'a waiter_set

external thread_repr : 'a t -> 'a thread_repr = "%identity"
external thread : 'a thread_repr -> 'a t = "%identity"
external wakener : 'a thread_repr -> 'a u = "%identity"
external wakener_repr : 'a u -> 'a thread_repr = "%identity"

(* Maximum number of disabled waiters a waiter set can contains before
   being cleaned: *)
let max_removed = 42

(* +-----------------------------------------------------------------+
   | Local storage                                                   |
   +-----------------------------------------------------------------+ *)

type 'a key = {
  id : int;
  mutable store : 'a option;
}

let next_key_id = ref 0

let new_key () =
  let id = !next_key_id in
  next_key_id := id + 1;
  { id = id; store = None }

let current_data = ref Int_map.empty

let get key =
  try
    Int_map.find key.id !current_data ();
    let value = key.store in
    key.store <- None;
    value
  with Not_found ->
    None

let set key value =
  match value with
    | Some _ ->
        thread { state = Return (); data = Int_map.add key.id (fun () -> key.store <- value) !current_data }
    | None ->
        thread { state = Return (); data = Int_map.remove key.id !current_data }

(* +-----------------------------------------------------------------+
   | Restarting/connecting threads                                   |
   +-----------------------------------------------------------------+ *)

(* Returns the representative of a thread, updating non-direct references: *)
let rec repr_rec t =
  match t.state with
    | Repr t' -> let t'' = repr_rec t' in if t'' != t' then t.state <- Repr t''; t''
    | _       -> t
let repr t = repr_rec (thread_repr t)

let rec run_waiters_rec state ws rem =
  match ws, rem with
    | Empty, [] ->
        ()
    | Empty, ws :: rem ->
        run_waiters_rec state ws rem
    | Immutable(data, f), [] ->
        current_data := data;
        f state
    | Immutable(data, f), ws :: rem ->
        current_data := data;
        f state;
        run_waiters_rec state ws rem
    | Removable(data, { contents = None }), [] ->
        ()
    | Removable(data, { contents = None }), ws :: rem ->
        run_waiters_rec state ws rem
    | Removable(data, { contents = Some f }), [] ->
        current_data := data;
        f state
    | Removable(data, { contents = Some f }), ws :: rem ->
        current_data := data;
        f state;
        run_waiters_rec state ws rem
    | Append(ws1, ws2), _ ->
        run_waiters_rec state ws1 (ws2 :: rem)

(* Run all waiters waiting on [t]: *)
let run_waiters waiters state =
  let save = !current_data in
  run_waiters_rec state waiters [];
  current_data := save

(* Restarts a sleeping thread [t]:

   - run all its waiters
   - set his state to the terminated state [state]
*)
let restart t state caller =
  let t = repr_rec (wakener_repr t) in
  match t.state with
    | Sleep{ waiters = waiters } ->
        t.state <- state;
        run_waiters waiters state
    | Fail Canceled ->
        (* Do not fail if the thread has been canceled: *)
        ()
    | _ ->
        invalid_arg caller

let restart_cancel t =
  let t = repr_rec (wakener_repr t) in
  match t.state with
    | Sleep{ waiters = waiters; cancel = cancel } ->
        let state = Fail Canceled in
        t.state <- state;
        run_waiters waiters state
    | _ ->
        ()

let wakeup t v = restart t (Return v) "Lwt.wakeup"
let wakeup_exn t e = restart t (Fail e) "Lwt.wakeup_exn"

let cancel t =
  match (repr t).state with
    | Sleep{ cancel = cancel } ->
        let f = !cancel in
        cancel := ignore;
        let save = !current_data in
        f ();
        current_data := save
    | _ ->
        ()

let append l1 l2 =
  match l1, l2 with
    | Empty, _ -> l2
    | _, Empty -> l1
    | _ -> Append(l1, l2)

(* Remove all disbaled waiters of a waiter set: *)
let rec cleanup = function
  | Removable(_, { contents = None }) ->
      Empty
  | Append(l1, l2) ->
      append (cleanup l1) (cleanup l2)
  | ws ->
      ws

(* Connects the two processes [t1] and [t2] when [t2] finishes up,
   where [t1] must be a sleeping thread.

   Connecting means running all the waiters for [t2] and assigning the
   state of [t1] to [t2].
*)
let connect t1 t2 =
  let t1 = repr t1 and t2 = repr t2 in
  match t1.state with
    | Sleep sleeper1 ->
        if t1 == t2 then
          (* Do nothing if the two threads already have the same
             representation *)
          ()
        else begin
          match t2.state with
            | Sleep sleeper2 ->
                (* If [t2] is sleeping, then makes it behave as [t1]: *)
                t2.state <- Repr t1;
                (* Note that the order is important: the user have no
                   access to [t2] but may keep a reference to [t1]. If
                   we inverse the order, i.e. we do:

                   [t1.state <- Repr t2]

                   then we have a possible leak. For example:

                   {[
                     let rec loop ()==
                       lwt () = Lwt_unix.yield () in
                       loop ()

                     lwt () =
                       let t = loop () in
                       ...
                   ]}

                   Here, after [n] iterations, [t] will contains:

                   [ref(Repr(ref(Repr(ref(Repr ... ref Sleep)))))]
                   \-------------[n]--------------/
                *)

                (* However, since [t1] is a temporary thread created
                   for a thread that is now terminated, its cancel
                   function is meaningless. Only the one of [t2] is
                   now important: *)
                sleeper1.cancel := !(sleeper2.cancel);

                (* Merge the two sets of waiters: *)
                let waiters = append sleeper1.waiters sleeper2.waiters
                and removed = sleeper1.removed + sleeper2.removed in
                if removed > max_removed then begin
                  (* Remove disabled threads *)
                  sleeper1.removed <- 0;
                  sleeper1.waiters <- cleanup waiters
                end else begin
                  sleeper1.removed <- removed;
                  sleeper1.waiters <- waiters
                end
            | state2 ->
                (* [t2] is already terminated, assing its state to [t1]: *)
                t1.state <- state2;
                (* and run all the waiters of [t1]: *)
                run_waiters sleeper1.waiters state2
        end
    | _ ->
        (* [t1] is not asleep: *)
        invalid_arg "Lwt.connect"

(* Same as [connect] except that we know that [t2] has terminated: *)
let fast_connect t state =
  let t = repr t in
  match t.state with
    | Sleep{ waiters = waiters } ->
        t.state <- state;
        run_waiters waiters state
    | _ ->
        invalid_arg "Lwt.fast_connect"

(* +-----------------------------------------------------------------+
   | Threads conctruction and combining                              |
   +-----------------------------------------------------------------+ *)

let return v =
  thread { state = Return v; data = !current_data }

let fail e =
  thread { state = Fail e; data = !current_data }

let temp data r =
  thread {
    state = Sleep{ cancel = r;
                   waiters = Empty;
                   removed = 0 };
    data = data;
  }

let wait () =
  let t = {
    state = Sleep{ cancel = ref ignore;
                   waiters = Empty;
                   removed = 0 };
    data = !current_data;
  } in
  (thread t, wakener t)

let task () =
  let rec t = {
    state = Sleep{ cancel = ref (fun () -> restart_cancel (wakener t));
                   waiters = Empty;
                   removed = 0 };
    data = !current_data;
  } in
  (thread t, wakener t)

(* apply function, reifying explicit exceptions into the thread type
   apply: ('a -(exn)-> 'b t) -> ('a -(n)-> 'b t)
   semantically a natural transformation TE -> T, where T is the thread
   monad, which is layered over exception monad E.
*)
let apply f x = try f x with e -> fail e

let apply_with_data data f x =
  if data == !current_data then
    (* We don't catch exceptions here so that tail recursion is not broken *)
    f x
  else begin
    let save = !current_data in
    current_data := data;
    try
      let result = f x in
      current_data := save;
      result
    with exn ->
      current_data := save;
      thread { state = Fail exn; data = data }
  end

let add_immutable_waiter sleeper data waiter =
  sleeper.waiters <- (match sleeper.waiters with
                        | Empty -> Immutable(data, waiter)
                        | _ -> Append(Immutable(data, waiter), sleeper.waiters))

let add_removable_waiter sleeper data waiter =
  sleeper.waiters <- (match sleeper.waiters with
                        | Empty -> Removable(data, waiter)
                        | _ -> Append(Removable(data, waiter), sleeper.waiters))

let on_cancel t f =
  match (repr t).state with
    | Sleep sleeper ->
        add_immutable_waiter sleeper (thread_repr t).data
          (function
             | Fail Canceled -> (try f () with _ -> ())
             | _ -> ())
    | Fail Canceled ->
        f ()
    | _ ->
        ()

let bind t f =
  match (repr t).state with
    | Return v ->
        apply_with_data (thread_repr t).data f v
    | Fail e ->
        thread { state = Fail e; data = (thread_repr t).data }
    | Sleep sleeper ->
        let res = temp (thread_repr t).data sleeper.cancel in
        add_immutable_waiter sleeper (thread_repr t).data
          (function
             | Return v -> connect res (try f v with exn -> fail exn)
             | Fail exn -> fast_connect res (Fail exn)
             | _ -> assert false);
        res
    | Repr _ ->
        assert false

let (>>=) t f = bind t f
let (=<<) f t = bind t f

let map f t =
  match (repr t).state with
    | Return v ->
        if (thread_repr t).data == !current_data then
          return (f v)
        else begin
          let save = !current_data in
          current_data := (thread_repr t).data;
          try
            let result = return (f v) in
            current_data := save;
            result
          with exn ->
            let result = fail exn in
            current_data := save;
            result
        end
    | Fail e ->
        thread { state = Fail e; data = (thread_repr t).data }
    | Sleep sleeper ->
        let res = temp (thread_repr t).data sleeper.cancel in
        add_immutable_waiter sleeper (thread_repr t).data
          (function
             | Return v -> fast_connect res (try Return(f v) with exn -> Fail exn)
             | Fail exn -> fast_connect res (Fail exn)
             | _ -> assert false);
        res
    | Repr _ ->
        assert false

let (>|=) t f = map f t
let (=|<) f t = map f t

let catch x f =
  let t = try x () with exn -> fail exn in
  match (repr t).state with
    | Return _ ->
        t
    | Fail exn ->
        apply_with_data (thread_repr t).data f exn
    | Sleep sleeper ->
        let res = temp (thread_repr t).data sleeper.cancel in
        add_immutable_waiter sleeper (thread_repr t).data
          (function
             | Return _ as state -> fast_connect res state
             | Fail exn -> connect res (try f exn with exn -> fail exn)
             | _ -> assert false);
        res
    | Repr _ ->
        assert false

let try_bind x f g =
  let t = try x () with exn -> fail exn in
  match (repr t).state with
    | Return v ->
        apply_with_data (thread_repr t).data f v
    | Fail exn ->
        apply_with_data (thread_repr t).data g exn
    | Sleep sleeper ->
        let res = temp (thread_repr t).data sleeper.cancel in
        add_immutable_waiter sleeper (thread_repr t).data
          (function
             | Return v -> connect res (try f v with exn -> fail exn)
             | Fail exn -> connect res (try g exn with exn -> fail exn)
             | _ -> assert false);
        res
    | Repr _ ->
        assert false

let poll t =
  match (repr t).state with
    | Fail e -> raise e
    | Return v -> Some v
    | Sleep _ -> None
    | Repr _ -> assert false

let rec ignore_result t =
  match (repr t).state with
    | Return v ->
        ()
    | Fail e ->
        raise e
    | Sleep sleeper ->
        add_immutable_waiter sleeper (thread_repr t).data
          (function
             | Return _ -> ()
             | Fail exn -> raise exn
             | _ -> assert false)
    | Repr _ ->
        assert false

let protected t =
  match (repr t).state with
    | Sleep sleeper ->
        let waiter, wakener = task () in
        add_immutable_waiter sleeper (thread_repr t).data
          (fun state ->
             try
               match state with
                 | Return v -> wakeup wakener v
                 | Fail exn -> wakeup_exn wakener exn
                 | _ ->  assert false
             with Invalid_argument _ ->
               ());
        waiter
    | Return _ | Fail _ ->
        t
    | Repr _ ->
        assert false

let rec nth_ready l n =
  match l with
    | [] ->
        assert false
    | t :: l ->
        match (repr t).state with
          | Sleep _ ->
              nth_ready l n
          | _ when n > 0 ->
              nth_ready l (n - 1)
          | _ ->
              t

let ready_count l =
  List.fold_left (fun acc x -> match (repr x).state with Sleep _ -> acc | _ -> acc + 1) 0 l

let remove_waiters l =
  List.iter
    (fun t ->
       match (repr t).state with
         | Sleep sleeper ->
             let removed = sleeper.removed + 1 in
             if removed > max_removed then begin
               sleeper.removed <- 0;
               sleeper.waiters <- cleanup sleeper.waiters
             end else
               sleeper.removed <- removed
         | _ ->
             ())
    l

let choose l =
  let ready = ready_count l in
  if ready > 0 then
    thread { thread_repr (nth_ready l (Random.int ready)) with data = !current_data }
  else begin
    let res = temp !current_data (ref (fun () -> List.iter cancel l)) in
    let rec waiter = ref (Some handle_result)
    and handle_result state =
      (* Disable the waiter now: *)
      waiter := None;
      (* Removes all waiters so we do not leak memory: *)
      remove_waiters l;
      (* This will not fail because it is called at most one time,
         since all other waiters have been removed: *)
      fast_connect res state
    in
    List.iter
      (fun t ->
         match (repr t).state with
           | Sleep sleeper ->
               (* The data passed here will never be used because
                  [handle_result] only calls [fast_connect] which
                  calls [run_waiters] which ignore the current data *)
               add_removable_waiter sleeper (thread_repr t).data waiter;
           | _ ->
               assert false)
      l;
    res
  end

let rec nchoose_terminate res acc = function
  | [] ->
      fast_connect res (Return(List.rev acc))
  | t :: l ->
      match (repr t).state with
        | Return x ->
            nchoose_terminate res (x :: acc) l
        | Fail _ as state ->
            fast_connect res state
        | _ ->
            nchoose_terminate res acc l

let nchoose_sleep l =
  let res = temp !current_data (ref (fun () -> List.iter cancel l)) in
  let rec waiter = ref (Some handle_result)
  and handle_result state =
    waiter := None;
    remove_waiters l;
    nchoose_terminate res [] l
  in
  List.iter
    (fun t ->
       match (repr t).state with
         | Sleep sleeper ->
             add_removable_waiter sleeper (thread_repr t).data waiter;
         | _ ->
             assert false)
    l;
  res

let nchoose l =
  let rec init = function
    | [] ->
        nchoose_sleep l
    | t :: l ->
        match (repr t).state with
          | Return x ->
              collect [x] l
          | Fail exn ->
              fail exn
          | _ ->
              init l
  and collect acc = function
    | [] ->
        return (List.rev acc)
    | t :: l ->
        match (repr t).state with
          | Return x ->
              collect (x :: acc) l
          | Fail exn ->
              fail exn
          | _ ->
              collect acc l
  in
  init l

(* Return the nth ready thread, and cancel all others *)
let rec cancel_and_nth_ready l n =
  match l with
    | [] ->
        assert false
    | t :: l ->
        match (repr t).state with
          | Sleep _ ->
              cancel t;
              nth_ready l n
          | _ when n > 0 ->
              nth_ready l (n - 1)
          | _ ->
              List.iter cancel l;
              t

let pick l =
  let ready = ready_count l in
  if ready > 0 then
    cancel_and_nth_ready l (Random.int ready)
  else begin
    let res = temp !current_data (ref (fun () -> List.iter cancel l)) in
    let rec waiter = ref (Some handle_result)
    and handle_result state =
      waiter := None;
      remove_waiters l;
      (* Cancel all other threads: *)
      List.iter cancel l;
      fast_connect res state
    in
    List.iter
      (fun t ->
         match (repr t).state with
           | Sleep sleeper ->
               add_removable_waiter sleeper (thread_repr t).data waiter;
           | _ ->
               assert false)
      l;
    res
  end

let npick_sleep l =
  let res = temp !current_data (ref (fun () -> List.iter cancel l)) in
  let rec waiter = ref (Some handle_result)
  and handle_result state =
    waiter := None;
    remove_waiters l;
    List.iter cancel l;
    nchoose_terminate res [] l
  in
  List.iter
    (fun t ->
       match (repr t).state with
         | Sleep sleeper ->
             add_removable_waiter sleeper (thread_repr t).data waiter;
         | _ ->
             assert false)
    l;
  res

let npick threads =
  let rec init = function
    | [] ->
        npick_sleep threads
    | t :: l ->
        match (repr t).state with
          | Return x ->
              collect [x] l
          | Fail exn ->
              List.iter cancel threads;
              fail exn
          | _ ->
              init l
  and collect acc = function
    | [] ->
        List.iter cancel threads;
        return (List.rev acc)
    | t :: l ->
        match (repr t).state with
          | Return x ->
              collect (x :: acc) l
          | Fail exn ->
              List.iter cancel threads;
              fail exn
          | _ ->
              collect acc l
  in
  init threads

let join l =
  let res = temp !current_data (ref (fun () -> List.iter cancel l))
  (* Number of threads still sleeping: *)
  and sleeping = ref 0
  (* The state that must be returned: *)
  and return_state = ref (Return ()) in
  let rec waiter = ref (Some handle_result)
  and handle_result state =
    begin
      match !return_state, state with
        | Return _, Fail _ -> return_state := state
        | _ -> ()
    end;
    decr sleeping;
    (* All threads are terminated, we can wakeup the result: *)
    if !sleeping = 0 then begin
      waiter := None;
      fast_connect res !return_state
    end
  in
  let rec init = function
    | [] ->
        if !sleeping = 0 then
          (* No thread is sleeping, returns immediately: *)
          thread { state = !return_state; data = !current_data }
        else
          res
    | t :: rest ->
        match (repr t).state with
          | Sleep sleeper ->
              incr sleeping;
              add_removable_waiter sleeper (thread_repr t).data waiter;
              init rest
          | Fail _ as state -> begin
              match !return_state with
                | Return _ ->
                    return_state := state;
                    init rest
                | _ ->
                    init rest
            end
          | _ ->
              init rest
  in
  init l

let ( <?> ) t1 t2 = choose [t1; t2]
let ( <&> ) t1 t2 = join [t1; t2]

let finalize f g =
  try_bind f
    (fun x -> g () >>= fun () -> return x)
    (fun e -> g () >>= fun () -> fail e)

module State = struct
  type 'a state =
    | Return of 'a
    | Fail of exn
    | Sleep
end

let state t = match (repr t).state with
  | Return v -> State.Return v
  | Fail exn -> State.Fail exn
  | Sleep _ -> State.Sleep
  | Repr _ -> assert false

include State

let paused = Lwt_sequence.create ()

let pause () =
  let waiter, wakener = task () in
  let node = Lwt_sequence.add_r wakener paused in
  on_cancel waiter (fun () -> Lwt_sequence.remove node);
  waiter

let rec wakeup_paused () =
  match Lwt_sequence.take_opt_l paused with
    | None ->
        ()
    | Some wakener ->
        wakeup wakener ();
        wakeup_paused ()
