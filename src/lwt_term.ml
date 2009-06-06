(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_term
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

open Lwt
open Lwt_text

(* +-----------------------------------------------------------------+
   | Terminal mode                                                   |
   +-----------------------------------------------------------------+ *)

let stdin_is_atty = lazy(Unix.isatty Unix.stdin)
let stdout_is_atty = lazy(Unix.isatty Unix.stdout)
let stderr_is_atty = lazy(Unix.isatty Unix.stderr)

type state =
  | Normal
  | Raw of Unix.terminal_io

let state = ref Normal

(* Number of function currently using the raw mode: *)
let raw_count = ref 0

let get_attr () =
  try
    Some(Unix.tcgetattr Unix.stdin)
  with
      _ -> None

let set_attr mode =
  try
    Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH mode
  with
      _ -> ()

let cursor_visible = ref true

let show_cursor _ =
  cursor_visible := true;
  write stdout "\x1B[?25h"

let hide_cursor _ =
  cursor_visible := false;
  write stdout "\x1B[?25l"

let clear_screen _ =
  write stdout "\027[2J\027[H"

(* Restore terminal mode on exit: *)
let cleanup () =
  begin
    if not !cursor_visible then
      show_cursor ()
    else
      return ()
  end >> match !state with
    | Normal ->
        return ()
    | Raw saved_attr ->
        set_attr saved_attr;
        return ()

let _ = Lwt_sequence.add_l cleanup Lwt_main.exit_hooks

let raw_mode () = match !state with
  | Normal -> false
  | Raw _ -> true

let leave_raw_mode () =
  decr raw_count;
  if !raw_count = 0 then
    match !state with
      | Normal ->
          assert false
      | Raw attr ->
          state := Normal;
          set_attr attr;
          return ()
  else
    return ()

let with_raw_mode f =
  match !state with
    | Raw attr ->
        incr raw_count;
        finalize f leave_raw_mode
    | Normal ->
        match get_attr () with
          | Some attr ->
              incr raw_count;
              state := Raw attr;
              set_attr {
                attr with
                  (* Inspired from Python-3.0/Lib/tty.py: *)
                  Unix.c_brkint = false;
                  Unix.c_inpck = false;
                  Unix.c_istrip = false;
                  Unix.c_ixon = false;
                  Unix.c_csize = 8;
                  Unix.c_parenb = false;
                  Unix.c_echo = false;
                  Unix.c_icanon = false;
                  Unix.c_isig = false;
                  Unix.c_vmin = 1;
                  Unix.c_vtime = 0
              };
              try_lwt f () finally leave_raw_mode ()
          | None ->
              fail (Failure "Lwt_term.with_raw_mode: input is not a tty")

(* +-----------------------------------------------------------------+
   | Terminal informations                                           |
   +-----------------------------------------------------------------+ *)

type size = {
  lines : int;
  columns : int;
}

external get_size : unit -> size = "lwt_unix_term_size"
external sigwinch : unit -> int = "lwt_unix_sigwinch"

let sigwinch_event =
  try
    (Lwt_unix.signal (sigwinch ()))#event
  with _ ->
    React.E.never

let size =
  React.S.hold
    (try get_size () with _ -> { columns = 80; lines = 25 })
    (React.E.map (fun _ -> get_size ()) sigwinch_event)

let columns = React.S.map (fun { columns = c } -> c) size
let lines = React.S.map (fun { lines = l } -> l) size

(* +-----------------------------------------------------------------+
   | Keys input                                                      |
   +-----------------------------------------------------------------+ *)

exception Exit_sequence

let parse_escape st =
  let buf = Buffer.create 10 in
  Buffer.add_char buf '\027';
  (* Read one character and add it to [buf]: *)
  let get () =
    match Lwt.state (Lwt_stream.get st) with
      | Sleep ->
          (* If the rest is not immediatly available, conclude that
             this is not an escape sequence but just the escape key: *)
          fail Exit_sequence
      | Fail exn ->
          fail exn
      | Return None ->
          fail Exit_sequence
      | Return(Some ch) ->
          (* Is it an ascii character ? *)
          if String.length ch = 1 then begin
            Buffer.add_string buf ch;
            return ch.[0]
          end else
            (* If it is not, then this is not an escape sequence: *)
            fail Exit_sequence
  in

  (* Sometimes sequences starts with several escape characters: *)
  let rec first count =
    get () >>= function
      | '\027' when count < 3 ->
          first (count + 1)
      | ch ->
          return ch
  in

  first 0 >>= function
    | '[' | 'O' ->
        let rec loop () =
          get () >>= function
            | '0' .. '9' | ';' ->
                loop ()
            | ch ->
                return (Buffer.contents buf)
        in
        loop ()

    | ch ->
        return (Buffer.contents buf)

let parse_key_raw st =
  Lwt_stream.next st >>= function
    | "\027" ->
        begin
          try_lwt
            Lwt_stream.parse st parse_escape
          with
              Exit_sequence -> return "\027"
        end
    | ch ->
        return ch

type key =
  | Key of string
  | Key_up
  | Key_down
  | Key_left
  | Key_right
  | Key_escape
  | Key_f of int
  | Key_enter
  | Key_next_page
  | Key_previous_page
  | Key_home
  | Key_end
  | Key_insert
  | Key_backspace
  | Key_delete
  | Key_tab
  | Key_control of char

let string_of_key = function
  | Key ch ->
      Printf.sprintf "Key %S" ch
  | Key_f n ->
      Printf.sprintf "Key_f %d" n
  | Key_control c ->
      Printf.sprintf "Key_control %C" c
  | Key_up ->
      "Key_up"
  | Key_down ->
      "Key_down"
  | Key_left ->
      "Key_left"
  | Key_right ->
      "Key_right"
  | Key_escape ->
      "Key_escape"
  | Key_enter ->
      "Key_enter"
  | Key_next_page ->
      "Key_next_page"
  | Key_previous_page ->
      "Key_previous_page"
  | Key_home ->
      "Key_home"
  | Key_end ->
      "Key_end"
  | Key_insert ->
      "Key_insert"
  | Key_backspace ->
      "Key_backspace"
  | Key_delete ->
      "Key_delete"
  | Key_tab ->
      "Key_tab"

let sequence_mapping = [
  "\027[A", Key_up;
  "\027[B", Key_down;
  "\027[C", Key_right;
  "\027[D", Key_left;
  "\027A", Key_up;
  "\027B", Key_down;
  "\027C", Key_right;
  "\027D", Key_left;
  "\027OA", Key_up;
  "\027OB", Key_down;
  "\027OC", Key_right;
  "\027OD", Key_left;
  "\027[2~", Key_insert;
  "\027[3~", Key_delete;
  "\027[5~", Key_previous_page;
  "\027[6~", Key_next_page;
  "\027[7~", Key_home;
  "\027[8~", Key_end;
  "\027[11~", Key_f 1;
  "\027[12~", Key_f 2;
  "\027[13~", Key_f 3;
  "\027[14~", Key_f 4;
  "\027[15~", Key_f 5;
  "\027[17~", Key_f 6;
  "\027[18~", Key_f 7;
  "\027[19~", Key_f 8;
  "\027[20~", Key_f 9;
  "\027[21~", Key_f 10;
  "\027[23~", Key_f 11;
  "\027[24~", Key_f 12;
  "\027OP", Key_f 1;
  "\027OQ", Key_f 2;
  "\027OR", Key_f 3;
  "\027OS", Key_f 4;
  "\027[H", Key_home;
  "\027[F", Key_end;
  "\027OH", Key_home;
  "\027OF", Key_end;
  "\027H", Key_home;
  "\027F", Key_end;
]

let control_mapping = [
  0x00, '@';
  0x01, 'a';
  0x02, 'b';
  0x03, 'c';
  0x04, 'd';
  0x05, 'e';
  0x06, 'f';
  0x07, 'g';
  0x08, 'h';
  0x09, 'i';
  0x0A, 'j';
  0x0B, 'k';
  0x0C, 'l';
  0x0D, 'm';
  0x0E, 'n';
  0x0F, 'o';
  0x10, 'p';
  0x11, 'q';
  0x12, 'r';
  0x13, 's';
  0x14, 't';
  0x15, 'u';
  0x16, 'v';
  0x17, 'w';
  0x18, 'x';
  0x19, 'y';
  0x1A, 'z';
  0x1B, '[';
  0x1C, '\\';
  0x1D, ']';
  0x1E, '^';
  0x1F, '_';
  0x7F, '?';
]

let decode_key ch =
  if ch = "" then invalid_arg "Lwt_term.decode_key";
  match ch with
    | "\x09" -> Key_tab
    | "\x0a" -> Key_enter
    | "\x1b" -> Key_escape
    | "\x7f" -> Key_backspace
    | ch when String.length ch = 1 ->
        begin try
          Key_control(List.assoc (Char.code ch.[0]) control_mapping)
        with
            Not_found -> Key ch
        end
    | ch ->
        begin try
          List.assoc ch sequence_mapping
        with
            Not_found -> Key ch
        end

let standard_input = Lwt_text.read_chars Lwt_text.stdin

let read_key () =
  with_raw_mode (fun _ -> parse_key_raw standard_input >|= decode_key)

(* +-----------------------------------------------------------------+
   | Styles                                                          |
   +-----------------------------------------------------------------+ *)

type color = int

let default = -1
let black = 0
let red = 1
let green = 2
let yellow = 3
let blue = 4
let magenta = 5
let cyan = 6
let white = 7
let lblack = black + 8
let lred = red + 8
let lgreen = green + 8
let lyellow = yellow + 8
let lblue = blue + 8
let lmagenta = magenta + 8
let lcyan = cyan + 8
let lwhite = white + 8

type style = {
  bold : bool;
  underlined : bool;
  blink : bool;
  inverse : bool;
  hidden : bool;
  foreground : color;
  background : color;
}

module Codes = struct
  let reset = 0
  let bold = 1
  let underlined = 4
  let blink = 5
  let inverse = 7
  let hidden = 8
  let foreground col = 30 + col
  let background col = 40 + col
end

let set_color num (r, g, b) =
  write stdout (Printf.sprintf "\027]4;%d;rgb:%02x/%02x/%02x;\027\\" num r g b)

(* +-----------------------------------------------------------------+
   | Rendering                                                       |
   +-----------------------------------------------------------------+ *)

type point = {
  char : string;
  style : style;
}

let blank = {
  char = " ";
  style = {
    bold = false;
    underlined = false;
    blink = false;
    inverse = false;
    hidden = false;
    foreground = default;
    background = default;
  };
}

let rec add_int buf = function
  | 0 ->
      ()
  | n ->
      add_int buf (n / 10);
      Buffer.add_char buf (Char.unsafe_chr (48 + (n mod 10)))

let render m =
  let buf = Buffer.create 16 in
  Lwt_text.atomic begin fun oc ->
    let rec loop_y y last_style =
      if y < Array.length m then
        let rec loop_x x last_style =
          if x < Array.length m.(y) then
            let pt = m.(y).(x) in
            begin
              if pt.style <> last_style then begin
                Buffer.clear buf;
                Buffer.add_string buf "\027[0";
                let mode n = function
                  | true ->
                      Buffer.add_char buf ';';
                      add_int buf n
                  | false ->
                      ()
                and color f col =
                  if col = default then
                    ()
                  else if col < 8 then begin
                    Buffer.add_char buf ';';
                    add_int buf (f col)
                  end else begin
                    Buffer.add_char buf ';';
                    add_int buf (f 8);
                    Buffer.add_string buf ";5;";
                    add_int buf col;
                  end
                in
                mode Codes.bold pt.style.bold;
                mode Codes.underlined pt.style.underlined;
                mode Codes.blink pt.style.blink;
                mode Codes.inverse pt.style.inverse;
                mode Codes.hidden pt.style.hidden;
                color Codes.foreground pt.style.foreground;
                color Codes.background pt.style.background;
                Buffer.add_char buf 'm';
                write oc (Buffer.contents buf)
              end else
                return ()
            end >>
              write_char oc pt.char >> loop_x (x + 1) pt.style
          else
            loop_y (y + 1) last_style
        in
        loop_x 0 last_style
      else
        return ()
    in
    (* Go to the top-left corner and reset attributes: *)
    write oc "\027[H\027[0m" >>
      loop_y 0 blank.style >>
      write oc "\027[0m"
  end stdout

(* +-----------------------------------------------------------------+
   | Styled text                                                     |
   +-----------------------------------------------------------------+ *)

open Printf

type styled_text_instruction =
  | Text of Text.t
  | Reset
  | Bold
  | Underlined
  | Blink
  | Inverse
  | Hidden
  | Foreground of color
  | Background of color

type styled_text = styled_text_instruction list

let textf fmt = Printf.ksprintf (fun txt -> Text txt) fmt
let text txt = Text txt
let reset = Reset
let bold = Bold
let underlined = Underlined
let blink = Blink
let inverse = Inverse
let hidden = Hidden
let fg col = Foreground col
let bg col = Background col

let strip_styles st =
  let buf = Buffer.create 42 in
  List.iter (function
               | Text t -> Buffer.add_string buf t
               | _ -> ()) st;
  Buffer.contents buf

let write_styled oc st =
  let buf = Buffer.create 16

  (* Pendings style codes: *)
  and codes = Queue.create () in

  (* Output pending codes using only one escape sequence: *)
  let output_pendings () =
    Buffer.clear buf;
    Buffer.add_string buf "\027[";
    add_int buf (Queue.take codes);
    Queue.iter (fun code ->
                  Buffer.add_char buf ';';
                  add_int buf code) codes;
    Queue.clear codes;
    Buffer.add_char buf 'm';
    write oc (Buffer.contents buf)
  in

  let rec loop = function
    | [] ->
        if not (Queue.is_empty codes) then
          output_pendings ()
        else
          return ()
    | instr :: rest ->
        match instr with
          | Text t  ->
              if not (Queue.is_empty codes) then
                output_pendings () >> write oc t >> loop rest
              else
                write oc t >> loop rest
          | Reset ->
              Queue.add 0 codes;
              loop rest
          | Bold ->
              Queue.add Codes.bold codes;
              loop rest
          | Underlined ->
              Queue.add Codes.underlined codes;
              loop rest
          | Blink ->
              Queue.add Codes.blink codes;
              loop rest
          | Inverse ->
              Queue.add Codes.inverse codes;
              loop rest
          | Hidden ->
              Queue.add Codes.hidden codes;
              loop rest
          | Foreground col ->
              if col = default then
                Queue.add (Codes.foreground 9) codes
              else if col < 8 then
                Queue.add (Codes.foreground col) codes
              else begin
                Queue.add (Codes.foreground 8) codes;
                Queue.add 5 codes;
                Queue.add col codes
              end;
              loop rest
          | Background col ->
              if col = default then
                Queue.add (Codes.background 9) codes
              else if col < 8 then
                Queue.add (Codes.background col) codes
              else begin
                Queue.add (Codes.background 8) codes;
                Queue.add 5 codes;
                Queue.add col codes
              end;
              loop rest
  in
  loop st

let styled_length st =
  let rec loop len = function
    | [] -> len
    | Text t :: l -> loop (len + Text.length t) l
    | _ :: l -> loop len l
  in
  loop 0 st

let printc st =
  if Lazy.force stdout_is_atty then
    atomic (fun oc -> write_styled oc st) stdout
  else
    write stdout (strip_styles st)

let eprintc st =
  if Lazy.force stderr_is_atty then
    atomic (fun oc -> write_styled oc st) stderr
  else
    write stderr (strip_styles st)

let fprintlc oc is_atty st =
  if Lazy.force is_atty then
    atomic (fun oc ->
              write_styled oc st
              >> write oc "\027[m"
              >> write_char oc "\n") oc
  else
    write_line oc (strip_styles st)

let printlc st = fprintlc stdout stdout_is_atty st
let eprintlc st = fprintlc stderr stderr_is_atty st
