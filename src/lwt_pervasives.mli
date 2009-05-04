(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_read_line
 * Copyright (C) 2009 Jérémie Dimino
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

(** Pervasives definitions *)

(** This modules defines aliases to function to other modules of Lwt,
    plus some helpers. *)

(** {6 Basic thread creation/manipulation and operators} *)

(** These definitions are the same as the ones from the {!Lwt}
    module: *)

val return : 'a -> 'a Lwt.t
val fail : exn -> 'a Lwt.t
val bind : 'a Lwt.t -> ('a -> 'b Lwt.t) -> 'b Lwt.t
val (>>=) : 'a Lwt.t -> ('a -> 'b Lwt.t) -> 'b Lwt.t
val (=<<) : ('a -> 'b Lwt.t) -> 'a Lwt.t -> 'b Lwt.t
val (>|=) : 'a Lwt.t -> ('a -> 'b) -> 'b Lwt.t
val (=|<) : ('a -> 'b) -> 'a Lwt.t -> 'b Lwt.t
val (<?>) : 'a Lwt.t -> 'a Lwt.t -> 'a Lwt.t
val (<&>) : unit Lwt.t -> unit Lwt.t -> unit Lwt.t

(** {6 IOs} *)

val input : Lwt_io.input Lwt_io.mode
val output : Lwt_io.output Lwt_io.mode

val stdin : Lwt_io.ic
val stdout : Lwt_io.oc
val stderr : Lwt_io.oc

val open_file :
  ?buffer_size : int ->
  ?encoding : Encoding.t ->
  ?flags : Unix.open_flag list ->
  ?perm : Unix.file_perm ->
  mode : 'a Lwt_io.mode ->
  string -> 'a Lwt_io.channel

val with_file :
  ?buffer_size : int ->
  ?encoding : Encoding.t ->
  ?flags : Unix.open_flag list ->
  ?perm : Unix.file_perm ->
  mode : 'a Lwt_io.mode ->
  string -> ('a Lwt_io.channel -> 'b Lwt.t) -> 'b Lwt.t

val close : 'a Lwt_io.channel -> unit Lwt.t

val read_char : Lwt_io.ic -> Text.t Lwt.t
val peek_char : Lwt_io.ic -> Text.t option Lwt.t
val read_text : Lwt_io.ic -> int -> Text.t Lwt.t
val read_line : Lwt_io.ic -> Text.t Lwt.t
val peek_line : Lwt_io.ic -> Text.t option Lwt.t

val write_char : Lwt_io.oc -> Text.t -> unit Lwt.t
val write_text : Lwt_io.oc -> Text.t -> unit Lwt.t
val write_line : Lwt_io.oc -> Text.t -> unit Lwt.t

(** {6 Printing facilities} *)

val print : Text.t -> unit Lwt.t
  (** [print txt = write_text stdout txt] *)

val printl : Text.t -> unit Lwt.t
  (** Same as [print] but also prints a newline after the text.

      If the terminal is in raw mode it use "\r\n" as newline,
      otherwise it uses "\n". *)

val printf : ('a, unit, Text.t, unit Lwt.t) format4 -> 'a
  (** [printf fmt ...] creates a text using the format string [fmt]
      and outputs it to stdout. *)

val printlf : ('a, unit, Text.t, unit Lwt.t) format4 -> 'a
  (** Same as {!printf} but also prints a newline after the text. *)

val eprint : Text.t -> unit Lwt.t
  (** Same as {!print} but prints on stderr *)

val eprintl : Text.t -> unit Lwt.t
  (** Same as {!print} but prints on stderr *)

val eprintf : ('a, unit, Text.t, unit Lwt.t) format4 -> 'a
  (** Same as {!printf} but prints on stderr *)

val eprintlf : ('a, unit, Text.t, unit Lwt.t) format4 -> 'a
  (** Same as {!printlf} but prints on stderr *)

(** {6 Styled printing} *)

val printc : Lwt_term.styled_text -> unit Lwt.t
val eprintc : Lwt_term.styled_text -> unit Lwt.t
val printlc : Lwt_term.styled_text -> unit Lwt.t
val eprintlc : Lwt_term.styled_text -> unit Lwt.t

val textf : ('a, unit, string, Lwt_term.styled_text_instruction) format4 -> 'a
  (** [textf fmt] formats a texts with [fmt] and returns
      [Lwt_term.Text txt] *)

val text : Text.t -> Lwt_term.styled_text_instruction
val reset : Lwt_term.styled_text_instruction
val bold : Lwt_term.styled_text_instruction
val underlined : Lwt_term.styled_text_instruction
val blink : Lwt_term.styled_text_instruction
val inverse : Lwt_term.styled_text_instruction
val hidden : Lwt_term.styled_text_instruction

val fg : Lwt_term.color -> Lwt_term.styled_text_instruction
  (** [fg col = Lwt_term.Foreground col] *)

val bg : Lwt_term.color -> Lwt_term.styled_text_instruction
  (** [bg col = Lwt_term.Background col] *)

val default : Lwt_term.color
val black : Lwt_term.color
val red : Lwt_term.color
val green : Lwt_term.color
val yellow : Lwt_term.color
val blue : Lwt_term.color
val magenta : Lwt_term.color
val cyan : Lwt_term.color
val white : Lwt_term.color
val default : Lwt_term.color

(** {6 Stream utilities} *)

val lines_of_channel : ?auto_close : bool -> Lwt_io.ic -> Text.t Lwt_stream.t
  (** [lines_of_channel ?auto_close ch] returns a streams holding all
      lines of [ch].

      @param auto_close tell whether automatically closing the channel
      on end-of-file. It defaults to [true] *)

val lines_to_channel : ?sep : Text.t -> Lwt_io.oc -> Text.t Lwt_stream.t -> unit Lwt.t
  (** [lines_to_channel ?sep ch lines] writes all lines of [lines] to
      [ch], separated by [sep], which defaults to ["\n"] *)

val lines_of_file : string -> Text.t Lwt_stream.t
  (** [lines_of_file filename] open [filename] and returns the stream
      of all its lines *)

val lines_to_file : ?sep : Text.t -> string -> Text.t Lwt_stream.t -> unit Lwt.t
  (** [lines_to_file ?sep filename lines] writes all lines of [lines]
      to [filename] *)

val lines_of_process : Lwt_process.command -> Text.t Lwt_stream.t
  (** [lines_of_process cmd] run [cmd] and returns its output as a
      stream of lines *)

val lines_to_process : ?sep : Text.t -> Lwt_process.command -> Text.t Lwt_stream.t -> unit Lwt.t
  (** [lines_to_process cmd lines] run [cmd] and send it all lines of
      [lines] *)
