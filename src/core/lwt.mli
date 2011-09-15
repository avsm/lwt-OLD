(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Interface Lwt
 * Copyright (C) 2005-2008 J�r�me Vouillon
 * Laboratoire PPS - CNRS Universit� Paris Diderot
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

(** Module [Lwt]: cooperative light-weight threads. *)

(** This module defines {e cooperative light-weight threads} with
    their primitives. A {e light-weight thread} represent a
    computation that may be not terminated, for example because it is
    waiting for some event to happen.

    Lwt threads are cooperative in the sense that switching to another
    thread is awlays explicit (with {!wakeup} or {!wekup_exn}). When a
    thread is running, it executes as much as possible, and then
    returns (a value or an eror) or sleeps.

    Note that inside a Lwt thread, exceptions must be raised with
    {!fail} instead of [raise]. Also the [try ... with ...]
    construction will not catch Lwt errors. You must use {!catch}
    instead. You can also use {!wrap} for functions that may raise
    normal exception.

    Lwt also provides the syntax extension {!Pa_lwt} to make code
    using Lwt more readable.
*)

(** {6 Definitions and basics} *)

type +'a t
  (** The type of threads returning a result of type ['a]. *)

val return : 'a -> 'a t
  (** [return e] is a thread whose return value is the value of the
      expression [e]. *)

val fail : exn -> 'a t
  (** [fail e] is a thread that fails with the exception [e]. *)

val bind : 'a t -> ('a -> 'b t) -> 'b t
  (** [bind t f] is a thread which first waits for the thread [t] to
      terminate and then, if the thread succeeds, behaves as the
      application of function [f] to the return value of [t].  If the
      thread [t] fails, [bind t f] also fails, with the same
      exception.

      The expression [bind t (fun x -> t')] can intuitively be read as
      [let x = t in t'], and if you use the {e lwt.syntax} syntax
      extension, you can write a bind operation like that: [lwt x = t in t'].

      Note that [bind] is also often used just for synchronization
      purpose: [t'] will not execute before [t] is terminated.

      The result of a thread can be bound several time. *)

val (>>=) : 'a t -> ('a -> 'b t) -> 'b t
  (** [t >>= f] is an alternative notation for [bind t f]. *)

val (=<<) : ('a -> 'b t) -> 'a t -> 'b t
  (** [f =<< t] is [t >>= f] *)

val map : ('a -> 'b) -> 'a t -> 'b t
  (** [map f m] map the result of a thread. This is the same as [bind
      m (fun x -> return (f x))] *)

val (>|=) : 'a t -> ('a -> 'b) -> 'b t
  (** [m >|= f] is [map f m] *)

val (=|<) : ('a -> 'b) -> 'a t -> 'b t
  (** [f =|< m] is [map f m] *)

(** {6 Thread storage} *)

type 'a key
  (** Type of a key. Keys are used to store local values into
      threads *)

val new_key : unit -> 'a key
  (** [new_key ()] creates a new key. *)

val get : 'a key -> 'a option
  (** [get key] returns the value associated with [key] in the current
      thread. *)

val with_value : 'a key -> 'a option -> (unit -> 'b) -> 'b
  (** [with_value key value f] executes [f] with [value] associated to
      [key]. The previous value associated to [key] is restored after
      [f] terminates. *)

(** {6 Exceptions handling} *)

val catch : (unit -> 'a t) -> (exn -> 'a t) -> 'a t
  (** [catch t f] is a thread that behaves as the thread [t ()] if
      this thread succeeds.  If the thread [t ()] fails with some
      exception, [catch t f] behaves as the application of [f] to this
      exception. *)

val try_bind : (unit -> 'a t) -> ('a -> 'b t) -> (exn -> 'b t) -> 'b t
  (** [try_bind t f g] behaves as [bind (t ()) f] if [t] does not
      fail.  Otherwise, it behaves as the application of [g] to the
      exception associated to [t ()]. *)

val finalize : (unit -> 'a t) -> (unit -> unit t) -> 'a t
  (** [finalize f g] returns the same result as [f ()] whether it
      fails or not. In both cases, [g ()] is executed after [f]. *)

val wrap : (unit -> 'a) -> 'a t
  (** [wrap f] calls [f] and transform the result into a monad. If [f]
      raise an exception, it is catched by Lwt.

      This is actually the same as:

      {[
        try
          return (f ())
        with exn ->
          fail exn
      ]}
  *)

val wrap1 : ('a -> 'b) -> 'a -> 'b t
  (** [wrap1 f x] applies [f] on [x] and returns the result as a
      thread. If the application of [f] to [x] raise an exception it
      is catched and a thread is returned.

      Note that you must use {!wrap} instead of {!wrap1} if the
      evaluation of [x] may raise an exception.

      for example the following code is not ok:

      {[
        wrap1 f (Hashtbl.find table key)
      ]}

      you should write instead:

      {[
        wrap (fun () -> f (Hashtbl.find table key))
      ]}
  *)

val wrap2 : ('a -> 'b -> 'c) -> 'a -> 'b -> 'c t
val wrap3 : ('a -> 'b -> 'c -> 'd) -> 'a -> 'b -> 'c -> 'd t
val wrap4 : ('a -> 'b -> 'c -> 'd -> 'e) -> 'a -> 'b -> 'c -> 'd -> 'e t
val wrap5 : ('a -> 'b -> 'c -> 'd -> 'e -> 'f) -> 'a -> 'b -> 'c -> 'd -> 'e -> 'f t
val wrap6 : ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g) -> 'a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g t
val wrap7 : ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h) -> 'a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h t

(** {6 Multi-threads composition} *)

val choose : 'a t list -> 'a t
  (** [choose l] behaves as the first thread in [l] to terminate.  If
      several threads are already terminated, one is choosen at
      random.

      Note: {!choose} leaves the local values of the current thread
      unchanged. *)

val nchoose : 'a t list -> 'a list t
  (** [nchoose l] returns the value of all that have succcessfully
      terminated. If all threads are sleeping, it waits for at least
      one to terminates. If one the threads of [l] fails, [nchoose]
      fails with the same exception.

      Note: {!nchoose} leaves the local values of the current thread
      unchanged. *)

val nchoose_split : 'a t list -> ('a list * 'a t list) t
  (** [nchoose_split l] does the same as {!nchoose} but also retrurns
      the list of threads that have not yet terminated. *)

val join : unit t list -> unit t
  (** [join l] waits for all threads in [l] to terminate. If one of
      the threads fails, then [join l] will fails with the same
      exception as the first one to terminate.

      Note: {!join} leaves the local values of the current thread
      unchanged. *)

val ( <?> ) : 'a t -> 'a t -> 'a t
  (** [t <?> t'] is the same as [choose [t; t']] *)

val ( <&> ) : unit t -> unit t -> unit t
  (** [t <&> t'] is the same as [join [t; t']] *)

val ignore_result : 'a t -> unit
  (** [ignore_result t] start the thread [t] and ignores its result
      value if the thread terminates sucessfully.  However, if the
      thread [t] fails, the exception is raised instead of being
      ignored.

      You should use this function if you want to start a thread and
      don't care what its return value is, nor when it terminates (for
      instance, because it is looping).  Note that if the thread [t]
      yields and later fails, the exception will not be raised at this
      point in the program. *)

(** {6 Sleeping and resuming} *)

type 'a u
  (** The type of thread wakeners. *)

val wait : unit -> 'a t * 'a u
  (** [wait ()] is a pair of a thread which sleeps forever (unless it
      is resumed by one of the functions [wakeup], [wakeup_exn] below)
      and the corresponding wakener.  This thread does not block the
      execution of the remainder of the program (except of course, if
      another thread tries to wait for its termination). *)

val wakeup : 'a u -> 'a -> unit
  (** [wakeup t e] makes the sleeping thread [t] terminate and return
      the value of the expression [e]. *)

val wakeup_exn : 'a u -> exn -> unit
  (** [wakeup_exn t e] makes the sleeping thread [t] fail with the
      exception [e]. *)

val wakeup_later : 'a u -> 'a -> unit
  (** Same as {!wakeup} but it is not guaranteed that the thread will
      be wakeup immediately. *)

val wakeup_later_exn : 'a u -> exn -> unit
  (** Same as {!wakeup_exn} but it is not guaranteed that the thread
      will be wakeup immediately. *)

val waiter_of_wakener : 'a u -> 'a t
  (** Returns the thread associated to a wakener. *)

(** {6 Threads state} *)

(** State of a thread *)
type 'a state =
  | Return of 'a
      (** The thread which has successfully terminated *)
  | Fail of exn
      (** The thread raised an exception *)
  | Sleep
      (** The thread is sleeping *)

val state : 'a t -> 'a state
  (** [state t] returns the state of a thread *)

(** {6 Cancelable threads} *)

(** Cancelable threads are the same as regular threads except that
    they can be canceled. *)

exception Canceled
  (** Canceled threads fails with this exception *)

val task : unit -> 'a t * 'a u
  (** [task ()] is the same as [wait ()] except that threads created
      with [task] can be canceled. *)

val on_cancel : 'a t -> (unit -> unit) -> unit
  (** [on_cancel t f] executes [f] when [t] is canceled. This is the
      same as catching [Canceled]. *)

val cancel : 'a t -> unit
  (** [cancel t] cancels the threads [t]. This means that the deepest
      sleeping thread created with [task] and connected to [t] is
      woken up with the exception {!Canceled}.

      For example, in the following code:

      {[
        let waiter, wakener = task () in
        cancel (waiter >> printl "plop")
      ]}

      [waiter] will be woken up with {!Canceled}.
  *)

val pick : 'a t list -> 'a t
  (** [pick l] is the same as {!choose}, except that it cancels all
      sleeping threads when one terminates.

      Note: {!pick} leaves the local values of the current thread
      unchanged. *)

val npick : 'a t list -> 'a list t
  (** [npick l] is the same as {!nchoose}, except that it cancels all
      sleeping threads when one terminates.

      Note: {!npick} leaves the local values of the current thread
      unchanged. *)

val protected : 'a t -> 'a t
  (** [protected thread] creates a new cancelable thread which behave
      as [thread] except that cancelling it does not cancel
      [thread]. *)

(** {6 Pause} *)

val pause : unit -> unit t
  (** [pause ()] is a sleeping thread which is wake up on the next
      call to {!wakeup_paused}. A thread created with [pause] can be
      canceled. *)

val wakeup_paused : unit -> unit
  (** [wakeup_paused ()] wakes up all threads which suspended
      themselves with {!pause}.

      This function is called by the scheduler, before entering the
      main loop. You usually do not have to call it directly, except
      if you are writing a custom scheduler.

      Note that if a paused thread resume and pause again, it will not
      be wakeup at this point. *)

val paused_count : unit -> int
  (** [paused_count ()] returns the number of thread currently
      paused. *)

val register_pause_notifier : (int -> unit) -> unit
  (** [register_pause_notifier f] register a function [f] that will be
      called each time pause is called. The parameter passed to [f] is
      the new number of threads paused. It is usefull to be able to
      call {!wakeup_paused} when there is no scheduler *)

(** {6 Misc} *)

val on_success : 'a t -> ('a -> unit) -> unit
  (** [on_success t f] executes [f] when [t] terminates without
      failing. This is the same as:

      {[
        ignore_result (bind t (fun x -> f x; return ()))
      ]}

      but a bit more efficient.
 *)

val on_failure : 'a t -> (exn -> unit) -> unit
  (** [on_failure t f] executes [f] when [t] terminates and
      fails. This is the same as:

      {[
        ignore_result (catch t (fun e -> f e; return ()))
      ]}

      but a bit more efficient.
  *)

val on_termination : 'a t -> (unit -> unit) -> unit
  (** [on_termination t f] executes [f] when [t] terminates. This is
      the same as:

      {[
        ignore_result (finalize (fun () -> t) (fun () -> f (); return ()))
      ]}

      but a bit more efficient.
  *)

(**/**)

(* The functions below are probably not useful for the casual user.
   They provide the basic primitives on which can be built multi-
   threaded libraries such as Lwt_unix. *)

val poll : 'a t -> 'a option
      (* [poll e] returns [Some v] if the thread [e] is terminated and
         returned the value [v].  If the thread failed with some
         exception, this exception is raised.  If the thread is still
         running, [poll e] returns [None] without blocking. *)

val apply : ('a -> 'b t) -> 'a -> 'b t
      (* [apply f e] apply the function [f] to the expression [e].  If
         an exception is raised during this application, it is caught
         and the resulting thread fails with this exception. *)
(* Q: Could be called 'glue' or 'trap' or something? *)

val backtrace_bind : (exn -> exn) -> 'a t -> ('a -> 'b t) -> 'b t
val backtrace_catch : (exn -> exn) -> (unit -> 'a t) -> (exn -> 'a t) -> 'a t
val backtrace_try_bind : (exn -> exn) -> (unit -> 'a t) -> ('a -> 'b t) -> (exn -> 'b t) -> 'b t
val backtrace_finalize : (exn -> exn) -> (unit -> 'a t) -> (unit -> unit t) -> 'a t

