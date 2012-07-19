(* Lwt
 * http://www.ocsigen.org
 * Copyright (C) 2008 J�r�me Vouillon
 *               2012 J�r�mie Dimino
 * Laboratoire PPS - CNRS Universit� Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later version.
 * See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(** Creating pools (for example pools of connections to a database). *)

(** Instead of creating a new connection each time you need one,
    keep a pool of opened connections and reuse opened connections
    that are free.
*)

type 'a t
  (** Type of pools *)

val create :
  int ->
  ?check : ('a -> (bool -> unit) -> unit) ->
  ?validate : ('a -> bool Lwt.t) ->
  (unit -> 'a Lwt.t) -> 'a t
  (** [create n ?check ?validate f] creates a new pool with at most
      [n] members. [f] is the function to use to create a new pool
      member.

      An element of the pool is validated by the optional [validate]
      function before its {!use}. Invalid elements are re-created.

      The optional function [check] is called after a [use] of an
      element failed. It must call its argument excatly one with
      [true] if the pool member is still valid and [false]
      otherwise. *)

val use : 'a t -> ('a -> 'b Lwt.t) -> 'b Lwt.t
  (** [use p f] takes one free member of the pool [p] and gives it to
      the function [f]. *)
