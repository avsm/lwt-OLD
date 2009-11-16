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

(** Interactive line input *)

(** {6 Definitions} *)

exception Interrupt
  (** Exception raised when the user press [Ctrl^D] *)

type edition_state = Text.t * Text.t
    (** An edition state, it is a pair of two UTF-8 encoded strings:

        - the input before the cursor
        - the input after the cursor *)

type prompt = Lwt_term.styled_text
    (** A prompt. It may contains colors. *)

type text_set = Set.Make(Text).t

(** {8 Completion} *)

(** Result of a completion function: *)
type completion_result = {
  comp_state : edition_state;
  (** The new edition state *)

  comp_words : text_set;
  (** A list of possibilities *)
}

type completion = edition_state -> completion_result Lwt.t
      (** Type of a completion function. It takes as argument the
          current edition state.

          Note: the thread launched by the completion function is
          cancelled using {!Lwt.cancel} if the user continue typing
          text. *)

val lookup : Text.t -> text_set -> (Text.t * text_set)
  (** [lookup word words] lookup for completion of [word] into
      [words]. It returns [(prefix, possibilities)] where
      [possibilities] are all words starting with [word] and [prefix]
      is the longest common prefix of [possibilities]. *)

val complete : ?suffix : Text.t -> Text.t -> Text.t -> Text.t -> text_set -> completion_result
  (** [complete ?suffix before word after words] basic completion
      functions. [words] is a list of possible completions for
      [word].

      If completion succeed [suffix] is append to the resulting
      text. It defaults to [" "]. *)

val print_words : Lwt_text.output_channel -> int -> string list -> unit Lwt.t
  (** [print_words oc columns strs] pretty-prints a list of words. *)

(** {8 History} *)

type history = Text.t list
    (** Type of an history *)

val add_entry : Text.t -> history -> history
  (** [add_entry line history] returns the history [history] plus
      [line] at the beginning. If [line] already appears at the
      beginning or contains only spaces, it is discarded. *)

val save_history : string -> history -> unit Lwt.t
  (** [save_history filename history] saves [history] to
      [filename]. History is saved by separating lines with a null
      character. *)

val load_history : string -> history Lwt.t
  (** [load_history filename] loads history from [filename]. Returns
      the empty history if the the file does not exit. *)

(** {8 Clipboards} *)

(** Type of a clipboard. *)
class clipboard : object
  method set : Text.t -> unit
  method contents : Text.t React.signal
end

val clipboard : clipboard
  (** The global clipboard. All read-line instances which do not use a
      specific clipboard use this one. *)

(** {6 High-level functions} *)

type completion_mode = [ `classic | `real_time ]
    (** The completion mode.

        - [`classic] means that when the user hit [Tab] a list of
          possible completions is proposed,

        - [`real_time] means that possible completions are shown to
          the user as he types, and he can navigate in them with
          [Tab+left], [Tab+right] *)

val read_line :
  ?history : history ->
  ?complete : completion ->
  ?clipboard : clipboard ->
  ?mode : completion_mode ->
  prompt : prompt -> unit -> Text.t Lwt.t
  (** [readline ?history ?complete ?mode ~prompt ()] inputs some text
      from the user. If input is not a terminal, it defaults to
      [Lwt_io.read_line Lwt_io.stdin].

      If @param mode contains the current completion mode. It default
      to [`real_time]. *)

type password_style = [ `empty | `clear | `text of Text.t ]
    (** Style which indicate how the password is echoed to the user:

        - with [`empty] nothing is printed
        - with [`clear] the password is displayed has it
        - with [`text ch] all characters are replaced by [ch] *)

val read_password :
  ?clipboard : clipboard ->
  ?style : password_style ->
  prompt : prompt -> unit -> Text.t Lwt.t
  (** [read_password ?clipboard ?clear ~prompt ()] inputs a password
      from the user. This function fails if input is not a terminal.

      @param style defaults to [`text "*"].
  *)

val read_keyword :
  ?history : history ->
  ?case_sensitive : bool ->
  ?mode : completion_mode ->
  prompt : prompt ->
  values :  (Text.t * 'value) list -> unit -> 'value Lwt.t
  (** [read_keyword ?history ?case_sensitive ?mode ~prompt ~keywords
      ()] reads one word which is a member of [words]. And returns
      which keyword the user choosed.

      [case_sensitive] default to [false]. *)

val read_yes_no : ?history : history -> ?mode : completion_mode -> prompt : prompt -> unit -> bool Lwt.t
  (** [read_yes_no ?history ?dynamic prompt ()] is the same as:

      {[
        read_keyword ?history ?dynamic prompt [("yes", true); ("no", false)] ()
      ]}
  *)

(** {6 Low-level interaction} *)

(** This part allow you to implements your own read-line function, or
    just to use the readline engine in another context (message box,
    ...). *)

(** Readline commands *)
module Command : sig

  (** Type of all read-line function: *)
  type t =
    | Nop
        (** Command which do nothing. Unknown keys maps to this commands. *)
    | Char of Text.t
        (** Any printable character. *)
    | Backward_delete_char
    | Forward_delete_char
    | Beginning_of_line
    | End_of_line
    | Complete
    | Meta_complete
    | Kill_line
    | Accept_line
    | Backward_delete_word
    | Forward_delete_word
    | History_next
    | History_previous
    | Break
    | Clear_screen
    | Insert
    | Refresh
    | Backward_char
    | Forward_char
    | Set_mark
    | Paste
    | Copy
    | Cut
    | Uppercase
    | Lowercase
    | Capitalize
    | Backward_word
    | Forward_word
    | Backward_search
    | Complete_left
    | Complete_right
    | Complete_up
    | Complete_down
    | Complete_first
    | Complete_last

  val to_string : t -> string
    (** [to_string cmd] returns a string representation of a command *)

  val of_key : Lwt_term.key -> t
    (** [of_key key] returns the command to which a key is mapped. *)
end

(** Engine *)
module Engine : sig

  (** Note: this part know nothing about rendering or completion. *)

  (** State when the user is doing selection: *)
  type selection_state = {
    sel_text : Text.t;
    (** The whole input text on which the selection is working *)
    sel_mark : Text.pointer;
    (** Pointer to the mark *)
    sel_cursor : Text.pointer;
    (** Pointer to the cursor *)
  }

  (** State when searching in the history *)
  type search_state = {
    search_word : Text.t;
    (** The word we are looking for *)
    search_history : history;
    (** Position in history. The first element is a sentence
        containing the searched word *)
    search_init_history : history;
    (** The initial history, before searching for a word *)
  }

  (** The engine mode: *)
  type mode =
    | Edition of edition_state
        (** The user is typing some text *)
    | Selection of selection_state
        (** The user is selecting some text *)
    | Search of search_state
        (** The user is searching the given word in the history *)

  (** An engine state: *)
  type state = {
    mode : mode;
    history : history * history;
    (** Cursor to the history position. *)
    completion : text_set;
    (** Possible completions for dynamic mode *)
    completion_index : int;
    (** Current position of the selection cursor *)
  }

  val init : history -> state
    (** [init history] return a initial state using the given
        history *)

  val reset : state -> state
    (** [reset state] reset the given state, if the user was doing a
        selection, it is canceled *)

  val update : engine_state : state -> ?clipboard : clipboard -> command : Command.t -> unit -> state
    (** [update ~state ?clipboard ~command ()] update an engine state by
        processing the given command. It returns the new state, and
        may have the side effect of changing the clipboard contents.

        [clipboard] defaults to the global clipboard.
    *)

  val edition_state : state -> edition_state
    (** Returns the edition state of a state, whatever its mode is. *)

  val all_input : state -> Text.t
    (** Returns the current complete user input. *)
end

(** Rendering to the terminal *)
module Terminal : sig

  type state
    (** State of rendering *)

  val init : state
    (** Initial state *)

  (** {6 High-level functions} *)

  (** The two following functions are the one used by read-line
      functions of this module. *)

  val draw :
    ?map_text : (Text.t -> Text.t) ->
    ?mode : completion_mode ->
    ?message : Text.t ->
    render_state : state ->
    engine_state : Engine.state ->
    prompt : prompt -> unit -> state Lwt.t
    (** [draw ?map_text ?dynamic state engine_state prompt] erase
        previous printed text, draw the new one, and return a new
        state for future redrawing.

        @param map_text is a function used to map user input before
        printing it, for example to hide passwords.

        @param message is a message to display if completion is not
        yet available. *)

  val last_draw :
    ?map_text : (Text.t -> Text.t) ->
    ?mode : completion_mode ->
    render_state : state ->
    engine_state : Engine.state ->
    prompt : prompt -> unit -> unit Lwt.t
    (** Draw for the last time, i.e. the cursor is left after the text
        and not at current position. *)

  (** {6 Low-level functions} *)

  (** The following functions are helpers in case you want to
      reimplement you own read-line function *)

  val expand_returns : columns : int -> text : Lwt_term.styled_text -> Lwt_term.styled_text
    (** [expand_returns st] returns [st] where all ["\n"] have
        been replaced by spaces until the end of line.

        For example:

        {[
          prepare_for_display ~columns:10 [Text "foo\nbar"] = [Text "foo       bar"]
        ]}

        This allow you to clean-up previously displayed text.
    *)
end

(** {6 Read-line classes} *)

(** Look at the "fancy_prompt.ml" example to see how to use this
    class *)

(** Basic class for all read-line ike functions. *)
class read_line_base : history -> object
  method prompt : prompt React.signal
    (** The prompt. It is a signal so it can change over time. It
        defaults to ["# "]. *)

  method engine_state : Engine.state React.signal
    (** The signal holding current engine state *)

  method set_engine_state : Engine.state -> unit
    (** Set the current engine state *)

  method edition_state : edition_state React.signal
    (** The signal holding current edition state *)

  method message : Text.t option React.signal
    (** Message to dislay while completion is being computed *)

  method set_message : Text.t option -> unit
    (** Set the current message *)

  method keys_pending : bool React.signal
    (** Signal which is [true] iff there are characters ready to be
        read on the standard input channel *)

  method clipboard : clipboard
    (** Which clipboard to use. It default to the default clipboard *)

  method mode : completion_mode
    (** The completion mode. It default to [`real_time] *)

  method map_text : Text.t -> Text.t
    (** [map_text txt] maps [txt] before printing it default to the
        identity. *)

  method refresh : unit
    (** Redraw current state *)

  method accept : unit
    (** Terminates line reading with acceptance *)

  method interrupt : unit
    (** Terminates line reading by user's interruption *)

  method process_command : Command.t -> unit Lwt.t
    (** Handle one command *)

  method reset : unit
    (** Reset engine state to its initial state *)

  method run : Text.t Lwt.t
    (** Start read-line, waits for termination, and returns the text
        written by the user *)
end

(** The class for {!read_line} *)
class read_line :
  ?history : history ->
  ?complete : completion ->
  ?clipboard : clipboard ->
  ?mode : completion_mode ->
  prompt : prompt -> unit -> read_line_base

(** The class for {!read_password} *)
class read_password :
  ?clipboard : clipboard ->
  ?style : password_style ->
  prompt : prompt -> unit -> read_line_base

(** The class for {!read_keyword} *)
class read_keyword :
  ?history : history ->
  ?case_sensitive : bool ->
  ?mode : completion_mode ->
  prompt : prompt ->
  values :  (Text.t * 'value) list -> unit -> read_line_base
