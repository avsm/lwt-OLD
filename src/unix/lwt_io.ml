(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_io
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

exception Channel_closed of string

(* Minimum size for buffers: *)
let min_buffer_size = 16

let check_buffer_size fun_name buffer_size =
  if buffer_size < min_buffer_size then
    Printf.ksprintf invalid_arg "Lwt_io.%s: too small buffer size (%d)" fun_name buffer_size
  else if buffer_size > Sys.max_string_length then
    Printf.ksprintf invalid_arg "Lwt_io.%s: too big buffer size (%d)" fun_name buffer_size
  else
    ()

let default_buffer_size = ref 4096

(* +-----------------------------------------------------------------+
   | Types                                                           |
   +-----------------------------------------------------------------+ *)

type input
type output

type 'a mode = Input | Output

let input : input mode = Input
let output : output mode = Output

(* A channel state *)
type 'mode state =
  | Busy_primitive
      (* A primitive is running on the channel *)

  | Busy_atomic of 'mode channel
      (* An atomic operations is being performed on the channel. The
         argument is the temporary atomic wrapper. *)

  | Waiting_for_busy
      (* A queued operation has not yet started. *)

  | Idle
      (* The channel is unused *)

  | Closed
      (* The channel has been closed *)

  | Invalid
      (* The channel is a temporary channel created for an atomic
         operation which has terminated. *)

(* A wrapper, which ensures that io operations are atomic: *)
and 'mode channel = {
  mutable state : 'mode state;

  channel : 'mode _channel;
  (* The real channel *)

  mutable queued : unit Lwt.u Lwt_sequence.t;
  (* Queued operations *)
}

and 'mode _channel = {
  mutable buffer : Lwt_bytes.t;
  mutable length : int;

  mutable ptr : int;
  (* Current position *)

  mutable max : int;
  (* Position of the end of data int the buffer. It is equal to
     [length] for output channels. *)

  abort_waiter : int Lwt.t;
  (* Thread which is wakeup with an exception when the channel is
     closed. *)
  abort_wakener : int Lwt.u;

  mutable auto_flushing : bool;
  (* Wether the auto-flusher is currently running or not *)

  main : 'mode channel;
  (* The main wrapper *)

  close : unit Lwt.t Lazy.t;
  (* Close function *)

  mode : 'mode mode;
  (* The channel mode *)

  mutable offset : int64;
  (* Number of bytes really read/written *)

  typ : typ;
  (* Type of the channel. *)
}

and typ =
  | Type_normal of (Lwt_bytes.t -> int -> int -> int Lwt.t) * (int64 -> Unix.seek_command -> int64 Lwt.t)
      (* The channel has been created with [make]. The first argument
         is the refill/flush function and the second is the seek
         function. *)
  | Type_bytes
      (* The channel has been created with [of_bytes]. *)

type input_channel = input channel
type output_channel = output channel

type direct_access = {
  da_buffer : Lwt_bytes.t;
  mutable da_ptr : int;
  mutable da_max : int;
  da_perform : unit -> int Lwt.t;
}

let mode wrapper = wrapper.channel.mode

(* +-----------------------------------------------------------------+
   | Creations, closing, locking, ...                                |
   +-----------------------------------------------------------------+ *)

module Outputs = Weak.Make(struct
                             type t = output_channel
                             let hash = Hashtbl.hash
                             let equal = ( == )
                           end)

(* Table of all opened output channels. On exit they are all
   flushed: *)
let outputs = Outputs.create 32

let position wrapper =
  let ch = wrapper.channel in
  match ch.mode with
    | Input ->
        Int64.sub ch.offset (Int64.of_int (ch.max - ch.ptr))
    | Output ->
        Int64.add ch.offset (Int64.of_int ch.ptr)

let name ch = match ch.mode with
  | Input -> "input"
  | Output -> "output"

let closed_channel ch = Channel_closed(name ch)
let invalid_channel ch = Failure(Printf.sprintf "temporary atomic %s channel no more valid" (name ch))

let is_busy ch =
  match ch.state with
    | Invalid ->
        raise (invalid_channel ch.channel)
    | Idle | Closed ->
        false
    | Busy_primitive | Busy_atomic _ | Waiting_for_busy ->
        true

(* Flush/refill the buffer. No race condition could happen because
   this function is always called atomically: *)
let perform_io ch = match ch.main.state with
  | Busy_primitive | Busy_atomic _ -> begin
      match ch.typ with
        | Type_normal(perform_io, seek) ->
            let ptr, len = match ch.mode with
              | Input ->
                  (* Size of data in the buffer *)
                  let size = ch.max - ch.ptr in
                  (* If there are still data in the buffer, keep them: *)
                  if size > 0 then Lwt_bytes.unsafe_blit ch.buffer ch.ptr ch.buffer 0 size;
                  (* Update positions: *)
                  ch.ptr <- 0;
                  ch.max <- size;
                  (size, ch.length - size)
              | Output ->
                  (0, ch.ptr) in
            lwt n = pick [ch.abort_waiter; perform_io ch.buffer ptr len] in
            (* Never trust user functions... *)
            if n < 0 || n > len then
              raise_lwt (Failure (Printf.sprintf "Lwt_io: invalid result of the [%s] function(request=%d,result=%d)"
                                    (match ch.mode with Input -> "read" | Output -> "write") len n))
            else begin
              (* Update the global offset: *)
              ch.offset <- Int64.add ch.offset (Int64.of_int n);
              (* Update buffer positions: *)
              begin match ch.mode with
                | Input ->
                    ch.max <- ch.max + n
                | Output ->
                    (* Shift remaining data: *)
                    let len = len - n in
                    Lwt_bytes.unsafe_blit ch.buffer n ch.buffer 0 len;
                    ch.ptr <- len
              end;
              return n
            end

        | Type_bytes -> begin
            match ch.mode with
              | Input ->
                  return 0
              | Output ->
                  raise_lwt (Failure "cannot flush a channel created with Lwt_io.of_string")
          end
    end

  | Closed ->
      raise_lwt (closed_channel ch)

  | Invalid ->
      raise_lwt (invalid_channel ch)

  | Idle | Waiting_for_busy ->
      assert false

let refill = perform_io
let flush_partial = perform_io

let rec flush_total oc =
  if oc.ptr > 0 then
    lwt _ = flush_partial oc in
    flush_total oc
  else
    return ()

let safe_flush_total oc =
  try_lwt
    flush_total oc
  with
      _ -> return ()

let deepest_wrapper ch =
  let rec loop wrapper =
    match wrapper.state with
      | Busy_atomic wrapper ->
          loop wrapper
      | _ ->
          wrapper
  in
  loop ch.main

let auto_flush oc =
  lwt () = Lwt.pause () in
  let wrapper = deepest_wrapper oc in
  match wrapper.state with
    | Busy_primitive | Waiting_for_busy ->
        (* The channel is used, cancel auto flushing. It will be
           restarted when the channel returns to the [Idle] state: *)
        oc.auto_flushing <- false;
        return ()

    | Busy_atomic _ ->
        (* Cannot happen since we took the deepest wrapper: *)
        assert false

    | Idle ->
        oc.auto_flushing <- false;
        wrapper.state <- Busy_primitive;
        lwt () = safe_flush_total oc in
        if wrapper.state = Busy_primitive then
          wrapper.state <- Idle;
        if not (Lwt_sequence.is_empty wrapper.queued) then
          wakeup_later (Lwt_sequence.take_l wrapper.queued) ();
        return ()

    | Closed | Invalid ->
        return ()

(* A ``locked'' channel is a channel in the state [Busy_primitive] or
   [Busy_atomic] *)

let unlock wrapper = match wrapper.state with
  | Busy_primitive | Busy_atomic _ ->
      if Lwt_sequence.is_empty wrapper.queued then
        wrapper.state <- Idle
      else begin
        wrapper.state <- Waiting_for_busy;
        wakeup_later (Lwt_sequence.take_l wrapper.queued) ()
      end;
      (* Launches the auto-flusher: *)
      let ch = wrapper.channel in
      if (* Launch the auto-flusher only if the channel is not busy: *)
        (wrapper.state = Idle &&
            (* Launch the auto-flusher only for output channel: *)
            ch.mode = Output &&
            (* Do not launch two auto-flusher: *)
            not ch.auto_flushing &&
            (* Do not launch the auto-flusher if operations are queued: *)
            Lwt_sequence.is_empty wrapper.queued) then begin
        ch.auto_flushing <- true;
        ignore (auto_flush ch)
      end

  | Closed | Invalid ->
      (* Do not change channel state if the channel has been closed *)
      if not (Lwt_sequence.is_empty wrapper.queued) then
        wakeup_later (Lwt_sequence.take_l wrapper.queued) ()

  | Idle | Waiting_for_busy ->
      (* We must never unlock an unlocked channel *)
      assert false

(* Wrap primitives into atomic io operations: *)
let primitive f wrapper = match wrapper.state with
  | Idle ->
      wrapper.state <- Busy_primitive;
      try_lwt
        f wrapper.channel
      finally
        unlock wrapper;
        return ()

  | Busy_primitive | Busy_atomic _ | Waiting_for_busy ->
      let (res, w) = task () in
      let node = Lwt_sequence.add_r w wrapper.queued in
      Lwt.on_cancel res (fun _ -> Lwt_sequence.remove node);
      lwt () = res in
      begin match wrapper.state with
        | Closed ->
            (* The channel has been closed while we were waiting *)
            unlock wrapper;
            raise_lwt (closed_channel wrapper.channel)

        | Idle | Waiting_for_busy ->
            wrapper.state <- Busy_primitive;
            try_lwt
              f wrapper.channel
            finally
              unlock wrapper;
              return ()

        | Invalid ->
            raise_lwt (invalid_channel wrapper.channel)

        | Busy_primitive | Busy_atomic _ ->
            assert false
      end

  | Closed ->
      raise_lwt (closed_channel wrapper.channel)

  | Invalid ->
      raise_lwt (invalid_channel wrapper.channel)

(* Wrap a sequence of io operations into an atomic operation: *)
let atomic f wrapper = match wrapper.state with
  | Idle ->
      let tmp_wrapper = { state = Idle;
                          channel = wrapper.channel;
                          queued = Lwt_sequence.create () } in
      wrapper.state <- Busy_atomic tmp_wrapper;
      try_lwt
        f tmp_wrapper
      finally
        (* The temporary wrapper is no more valid: *)
        tmp_wrapper.state <- Invalid;
        unlock wrapper;
        return ()

  | Busy_primitive | Busy_atomic _ | Waiting_for_busy ->
      let (res, w) = task () in
      let node = Lwt_sequence.add_r w wrapper.queued in
      Lwt.on_cancel res (fun _ -> Lwt_sequence.remove node);
      lwt () = res in
      begin match wrapper.state with
        | Closed ->
            (* The channel has been closed while we were waiting *)
            unlock wrapper;
            raise_lwt (closed_channel wrapper.channel)

        | Idle | Waiting_for_busy ->
            let tmp_wrapper = { state = Idle;
                                channel = wrapper.channel;
                                queued = Lwt_sequence.create () } in
            wrapper.state <- Busy_atomic tmp_wrapper;
            try_lwt
              f tmp_wrapper
            finally
              tmp_wrapper.state <- Invalid;
              unlock wrapper;
              return ()

        | Invalid ->
            raise_lwt (invalid_channel wrapper.channel)

        | Busy_primitive | Busy_atomic _ ->
            assert false
      end

  | Closed ->
      raise_lwt (closed_channel wrapper.channel)

  | Invalid ->
      raise_lwt (invalid_channel wrapper.channel)

let rec abort wrapper = match wrapper.state with
  | Busy_atomic tmp_wrapper ->
      (* Close the depest opened wrapper: *)
      abort tmp_wrapper
  | Closed ->
      (* Double close, just returns the same thing as before *)
      Lazy.force wrapper.channel.close
  | Invalid ->
      raise_lwt (invalid_channel wrapper.channel)
  | Idle | Busy_primitive | Waiting_for_busy ->
      wrapper.state <- Closed;
      (* Abort any current real reading/writing operation on the
         channel: *)
      wakeup_exn wrapper.channel.abort_wakener (closed_channel wrapper.channel);
      Lazy.force wrapper.channel.close

let close wrapper =
  let channel = wrapper.channel in
  if channel.main != wrapper then
    raise_lwt (Failure "Lwt_io.close: cannot close a channel obtained via Lwt_io.atomic")
  else
    match channel.mode with
      | Input ->
          (* Just close it now: *)
          abort wrapper
      | Output ->
          try_lwt
            (* Performs all pending actions, flush the buffer, then
               close it: *)
            primitive (fun channel -> safe_flush_total channel >> abort wrapper) wrapper
          with _ ->
            abort wrapper

let () =
  (* Flush all opened ouput channels on exit: *)
  Lwt_main.at_exit
    (fun () ->
       let wrappers = Outputs.fold (fun x l -> x :: l) outputs [] in
       Lwt_list.iter_p
         (fun wrapper ->
            try_lwt
              primitive safe_flush_total wrapper
            with _ ->
              return ())
         wrappers)

let no_seek pos cmd =
  raise_lwt (Failure "Lwt_io.seek: seek not supported on this channel")

external unsafe_output : 'a channel -> output channel = "%identity"

let make ?buffer_size ?(close=return) ?(seek=no_seek) ~mode perform_io =
  let size =
    match buffer_size with
      | None ->
          !default_buffer_size
      | Some size ->
          check_buffer_size "Lwt_io.make" size;
          size
  in
  let buffer = Lwt_bytes.create size and abort_waiter, abort_wakener = Lwt.wait () in
  let rec ch = {
    buffer = buffer;
    length = size;
    ptr = 0;
    max = (match mode with
             | Input -> 0
             | Output -> size);
    close = lazy(try_lwt close ());
    abort_waiter = abort_waiter;
    abort_wakener = abort_wakener;
    main = wrapper;
    auto_flushing = false;
    mode = mode;
    offset = 0L;
    typ = Type_normal(perform_io, fun pos cmd -> try seek pos cmd with e -> raise_lwt e);
  } and wrapper = {
    state = Idle;
    channel = ch;
    queued = Lwt_sequence.create ();
  } in
  if mode = Output then Outputs.add outputs (unsafe_output wrapper);
  wrapper

let of_bytes ~mode bytes =
  let length = Lwt_bytes.length bytes in
  let abort_waiter, abort_wakener = Lwt.wait () in
  let rec ch = {
    buffer = bytes;
    length = length;
    ptr = 0;
    max = length;
    close = lazy(return ());
    abort_waiter = abort_waiter;
    abort_wakener = abort_wakener;
    main = wrapper;
    (* Auto flush is set to [true] to prevent writing functions from
       trying to launch the auto-fllushed. *)
    auto_flushing = true;
    mode = mode;
    offset = 0L;
    typ = Type_bytes;
  } and wrapper = {
    state = Idle;
    channel = ch;
    queued = Lwt_sequence.create ();
  } in
  wrapper

let of_string ~mode str = of_bytes ~mode (Lwt_bytes.of_string str)

let of_fd ?buffer_size ?close ~mode fd =
  let perform_io = match mode with
    | Input -> Lwt_bytes.read fd
    | Output -> Lwt_bytes.write fd
  in
  make
    ?buffer_size
    ~close:(match close with
              | Some f -> f
              | None -> (fun () -> Lwt_unix.close fd))
    ~seek:(fun pos cmd -> Lwt_unix.LargeFile.lseek fd pos cmd)
    ~mode
    perform_io

let of_unix_fd ?buffer_size ?close ~mode fd =
  of_fd ?buffer_size ?close ~mode (Lwt_unix.of_unix_file_descr fd)

let buffered ch =
  match ch.channel.mode with
    | Input -> ch.channel.max - ch.channel.ptr
    | Output -> ch.channel.ptr

let buffer_size ch = ch.channel.length

let resize_buffer wrapper len =
  if len < min_buffer_size then invalid_arg "Lwt_io.resize_buffer";
  match wrapper.channel.typ with
    | Type_bytes ->
        raise_lwt (Failure "Lwt_io.resize_buffer: cannot resize the buffer of a channel created with Lwt_io.of_string")
    | Type_normal _ ->
        primitive begin fun ch ->
          match ch.mode with
            | Input ->
                let unread_count = ch.max - ch.ptr in
                (* Fail if we want to decrease the buffer size and there is
                   too much unread data in the buffer: *)
                if len < unread_count then
                  raise_lwt (Failure "Lwt_io.resize_buffer: cannot decrease buffer size")
                else begin
                  let buffer = Lwt_bytes.create len in
                  Lwt_bytes.unsafe_blit ch.buffer ch.ptr buffer 0 unread_count;
                  ch.buffer <- buffer;
                  ch.length <- len;
                  ch.ptr <- 0;
                  ch.max <- unread_count;
                  return ()
                end
            | Output ->
                (* If we decrease the buffer size, flush the buffer until
                   the number of buffered bytes fits into the new buffer: *)
                let rec loop () =
                  if ch.ptr > len then
                    lwt _ = flush_partial ch in
                    loop ()
                  else
                    return ()
                in
                lwt () = loop () in
                let buffer = Lwt_bytes.create len in
                Lwt_bytes.unsafe_blit ch.buffer 0 buffer 0 ch.ptr;
                ch.buffer <- buffer;
                ch.length <- len;
                ch.max <- len;
                return ()
        end wrapper

(* +-----------------------------------------------------------------+
   | Byte-order                                                      |
   +-----------------------------------------------------------------+ *)

module ByteOrder =
struct
  module type S = sig
    val pos16_0 : int
    val pos16_1 : int
    val pos32_0 : int
    val pos32_1 : int
    val pos32_2 : int
    val pos32_3 : int
    val pos64_0 : int
    val pos64_1 : int
    val pos64_2 : int
    val pos64_3 : int
    val pos64_4 : int
    val pos64_5 : int
    val pos64_6 : int
    val pos64_7 : int
  end

  module LE =
  struct
    let pos16_0 = 0
    let pos16_1 = 1
    let pos32_0 = 0
    let pos32_1 = 1
    let pos32_2 = 2
    let pos32_3 = 3
    let pos64_0 = 0
    let pos64_1 = 1
    let pos64_2 = 2
    let pos64_3 = 3
    let pos64_4 = 4
    let pos64_5 = 5
    let pos64_6 = 6
    let pos64_7 = 7
  end

  module BE =
  struct
    let pos16_0 = 1
    let pos16_1 = 0
    let pos32_0 = 3
    let pos32_1 = 2
    let pos32_2 = 1
    let pos32_3 = 0
    let pos64_0 = 7
    let pos64_1 = 6
    let pos64_2 = 5
    let pos64_3 = 4
    let pos64_4 = 3
    let pos64_5 = 2
    let pos64_6 = 1
    let pos64_7 = 0
  end
end

module Primitives =
struct

  (* This module contains all primitives operations. The operates
     without protection regarding locking, they are wrapped after into
     safe operations. *)

  (* +---------------------------------------------------------------+
     | Reading                                                       |
     +---------------------------------------------------------------+ *)

  let rec read_char ic =
    let ptr = ic.ptr in
    if ptr = ic.max then
      refill ic >>= function
        | 0 -> raise_lwt End_of_file
        | _ -> read_char ic
    else begin
      ic.ptr <- ptr + 1;
      return (Lwt_bytes.unsafe_get ic.buffer ptr)
    end

  let read_char_opt ic =
    try_lwt
      read_char ic >|= fun ch -> Some ch
    with End_of_file ->
      return None

  let read_line ic =
    let buf = Buffer.create 128 in
    let rec loop cr_read =
      try_bind (fun _ -> read_char ic)
        (function
           | '\n' ->
               return(Buffer.contents buf)
           | '\r' ->
               if cr_read then Buffer.add_char buf '\r';
               loop true
           | ch ->
               if cr_read then Buffer.add_char buf '\r';
               Buffer.add_char buf ch;
               loop false)
        (function
           | End_of_file ->
               if cr_read then Buffer.add_char buf '\r';
               return(Buffer.contents buf)
           | exn ->
               raise_lwt exn)
    in
    read_char ic >>= function
      | '\r' -> loop true
      | '\n' -> return ""
      | ch -> Buffer.add_char buf ch; loop false

  let read_line_opt ic =
    try_lwt
      read_line ic >|= fun ch -> Some ch
    with End_of_file ->
      return None

  let unsafe_read_into ic str ofs len =
    let avail = ic.max - ic.ptr in
    if avail > 0 then begin
      let len = min len avail in
      Lwt_bytes.unsafe_blit_bytes_string ic.buffer ic.ptr str ofs len;
      ic.ptr <- ic.ptr + len;
      return len
    end else begin
      refill ic >>= fun n ->
        let len = min len n in
        Lwt_bytes.unsafe_blit_bytes_string ic.buffer 0 str ofs len;
        ic.ptr <- len;
        ic.max <- n;
        return len
    end

  let read_into ic str ofs len =
    if ofs < 0 || len < 0 || ofs + len > String.length str then
      raise_lwt (Invalid_argument (Printf.sprintf
                                     "Lwt_io.read_into(ofs=%d,len=%d,str_len=%d)"
                                     ofs len (String.length str)))
    else begin
      if len = 0 then
        return 0
      else
        unsafe_read_into ic str ofs len
    end

  let rec unsafe_read_into_exactly ic str ofs len =
    unsafe_read_into ic str ofs len >>= function
      | 0 ->
          raise_lwt End_of_file
      | n ->
          let len = len - n in
          if len = 0 then
            return ()
          else
            unsafe_read_into_exactly ic str (ofs + n) len

  let read_into_exactly ic str ofs len =
    if ofs < 0 || len < 0 || ofs + len > String.length str then
      raise_lwt (Invalid_argument (Printf.sprintf
                                     "Lwt_io.read_into_exactly(ofs=%d,len=%d,str_len=%d)"
                                     ofs len (String.length str)))
    else begin
      if len = 0 then
        return ()
      else
        unsafe_read_into_exactly ic str ofs len
    end

  let rev_concat len l =
    let buf = String.create len in
    let _ =
      List.fold_left
        (fun ofs str ->
           let len = String.length str in
           let ofs = ofs - len in
           String.unsafe_blit str 0 buf ofs len;
           ofs)
        len l
    in
    buf

  let rec read_all ic total_len acc =
    let len = ic.max - ic.ptr in
    let str = String.create len in
    Lwt_bytes.unsafe_blit_bytes_string ic.buffer ic.ptr str 0 len;
    ic.ptr <- ic.max;
    refill ic >>= function
      | 0 ->
          return (rev_concat (len + total_len) (str :: acc))
      | n ->
          read_all ic (len + total_len) (str :: acc)

  let read count ic =
    match count with
      | None ->
          read_all ic 0 []
      | Some len ->
          let str = String.create len in
          lwt real_len = unsafe_read_into ic str 0 len in
          if real_len < len then
            return (String.sub str 0 real_len)
          else
            return str

  let read_value ic =
    let header = String.create 20 in
    lwt () = unsafe_read_into_exactly ic header 0 20 in
    let bsize = Marshal.data_size header 0 in
    let buffer = String.create (20 + bsize) in
    String.unsafe_blit header 0 buffer 0 20;
    lwt () = unsafe_read_into_exactly ic buffer 20 bsize in
    return (Marshal.from_string buffer 0)

  (* +---------------------------------------------------------------+
     | Writing                                                       |
     +---------------------------------------------------------------+ *)

  let flush = flush_total

  let rec write_char oc ch =
    let ptr = oc.ptr in
    if ptr < oc.length then begin
      oc.ptr <- ptr + 1;
      Lwt_bytes.unsafe_set oc.buffer ptr ch;
      return ()
    end else
      lwt _ = flush_partial oc in
      write_char oc ch

  let rec unsafe_write_from oc str ofs len =
    let avail = oc.length - oc.ptr in
    if avail >= len then begin
      Lwt_bytes.unsafe_blit_string_bytes str ofs oc.buffer oc.ptr len;
      oc.ptr <- oc.ptr + len;
      return 0
    end else begin
      Lwt_bytes.unsafe_blit_string_bytes str ofs oc.buffer oc.ptr avail;
      oc.ptr <- oc.length;
      lwt _ = flush_partial oc in
      let len = len - avail in
      if oc.ptr = 0 then begin
        if len = 0 then
          return 0
        else
          (* Everything has been written, try to write more: *)
          unsafe_write_from oc str (ofs + avail) len
      end else
        (* Not everything has been written, just what is
           remaining: *)
        return len
    end

  let write_from oc str ofs len =
    if ofs < 0 || len < 0 || ofs + len > String.length str then
      raise_lwt (Invalid_argument (Printf.sprintf
                                     "Lwt_io.write_from(ofs=%d,len=%d,str_len=%d)"
                                     ofs len (String.length str)))
    else begin
      if len = 0 then
        return 0
      else
        unsafe_write_from oc str ofs len >>= fun remaining -> return (len - remaining)
    end

  let rec unsafe_write_from_exactly oc str ofs len =
    unsafe_write_from oc str ofs len >>= function
      | 0 ->
          return ()
      | n ->
          unsafe_write_from_exactly oc str (ofs + len - n) n

  let write_from_exactly oc str ofs len =
    if ofs < 0 || len < 0 || ofs + len > String.length str then
      raise_lwt (Invalid_argument (Printf.sprintf
                                     "Lwt_io.write_from_exactly(ofs=%d,len=%d,str_len=%d)"
                                     ofs len (String.length str)))
    else begin
      if len = 0 then
        return ()
      else
        unsafe_write_from_exactly oc str ofs len
    end

  let write oc str =
    unsafe_write_from_exactly oc str 0 (String.length str)

  let write_line oc str =
    lwt () = unsafe_write_from_exactly oc str 0 (String.length str) in
    write_char oc '\n'

  let write_value oc ?(flags=[]) x =
    write oc (Marshal.to_string x flags)

  (* +---------------------------------------------------------------+
     | Low-level access                                              |
     +---------------------------------------------------------------+ *)

  let rec read_block_unsafe ic size f =
    if ic.max - ic.ptr < size then
      refill ic >>= function
        | 0 ->
            raise_lwt End_of_file
        | _ ->
            read_block_unsafe ic size f
    else begin
      let ptr = ic.ptr in
      ic.ptr <- ptr + size;
      f ic.buffer ptr
    end

  let rec write_block_unsafe oc size f =
    if oc.max - oc.ptr < size then
      lwt _ = flush_partial oc in
      write_block_unsafe oc size f
    else begin
      let ptr = oc.ptr in
      oc.ptr <- ptr + size;
      f oc.buffer ptr
    end

  let block ch size f =
    if size < 0 || size > min_buffer_size then
      raise_lwt (Invalid_argument(Printf.sprintf "Lwt_io.block(size=%d)" size))
    else
      if ch.max - ch.ptr >= size then begin
        let ptr = ch.ptr in
        ch.ptr <- ptr + size;
        f ch.buffer ptr
      end else
        match ch.mode with
          | Input ->
              read_block_unsafe ch size f
          | Output ->
              write_block_unsafe ch size f

  let perform token da ch =
    if !token then begin
      if da.da_max <> ch.max || da.da_ptr < ch.ptr || da.da_ptr > ch.max then
        raise_lwt (Invalid_argument "Lwt_io.direct_access.perform")
      else begin
        ch.ptr <- da.da_ptr;
        lwt count = perform_io ch in
        da.da_ptr <- ch.ptr;
        da.da_max <- ch.max;
        return count
      end
    end else
      raise_lwt (Failure "Lwt_io.direct_access.perform: this function can not be called outside Lwt_io.direct_access")

  let direct_access ch f =
    let token = ref true in
    let rec da = {
      da_ptr = ch.ptr;
      da_max = ch.max;
      da_buffer = ch.buffer;
      da_perform = (fun _ -> perform token da ch);
    } in
    lwt x = f da in
    token := false;
    if da.da_max <> ch.max || da.da_ptr < ch.ptr || da.da_ptr > ch.max then
      raise_lwt (Failure "Lwt_io.direct_access: invalid result of [f]")
    else begin
      ch.ptr <- da.da_ptr;
      return x
    end

  module MakeNumberIO(ByteOrder : ByteOrder.S) =
  struct
    open ByteOrder

    (* +-------------------------------------------------------------+
       | Reading numbers                                             |
       +-------------------------------------------------------------+ *)

    let get buffer ptr = Char.code (Lwt_bytes.unsafe_get buffer ptr)

    let read_int ic =
      read_block_unsafe ic 4
        (fun buffer ptr ->
           let v0 = get buffer (ptr + pos32_0)
           and v1 = get buffer (ptr + pos32_1)
           and v2 = get buffer (ptr + pos32_2)
           and v3 = get buffer (ptr + pos32_3) in
           let v = v0 lor (v1 lsl 8) lor (v2 lsl 16) lor (v3 lsl 24) in
           if v3 land 0x80 = 0 then
             return v
           else
             return (v - (1 lsl 32)))

    let read_int16 ic =
      read_block_unsafe ic 2
        (fun buffer ptr ->
           let v0 = get buffer (ptr + pos16_0)
           and v1 = get buffer (ptr + pos16_1) in
           let v = v0 lor (v1 lsl 8) in
           if v1 land 0x80 = 0 then
             return v
           else
             return (v - (1 lsl 16)))

    let read_int32 ic =
      read_block_unsafe ic 4
        (fun buffer ptr ->
           let v0 = get buffer (ptr + pos32_0)
           and v1 = get buffer (ptr + pos32_1)
           and v2 = get buffer (ptr + pos32_2)
           and v3 = get buffer (ptr + pos32_3) in
           return (Int32.logor
                     (Int32.logor
                        (Int32.of_int v0)
                        (Int32.shift_left (Int32.of_int v1) 8))
                     (Int32.logor
                        (Int32.shift_left (Int32.of_int v2) 16)
                        (Int32.shift_left (Int32.of_int v3) 24))))

    let read_int64 ic =
      read_block_unsafe ic 8
        (fun buffer ptr ->
           let v0 = get buffer (ptr + pos64_0)
           and v1 = get buffer (ptr + pos64_1)
           and v2 = get buffer (ptr + pos64_2)
           and v3 = get buffer (ptr + pos64_3)
           and v4 = get buffer (ptr + pos64_4)
           and v5 = get buffer (ptr + pos64_5)
           and v6 = get buffer (ptr + pos64_6)
           and v7 = get buffer (ptr + pos64_7) in
           return (Int64.logor
                     (Int64.logor
                        (Int64.logor
                           (Int64.of_int v0)
                           (Int64.shift_left (Int64.of_int v1) 8))
                        (Int64.logor
                           (Int64.shift_left (Int64.of_int v2) 16)
                           (Int64.shift_left (Int64.of_int v3) 24)))
                     (Int64.logor
                        (Int64.logor
                           (Int64.shift_left (Int64.of_int v4) 32)
                           (Int64.shift_left (Int64.of_int v5) 40))
                        (Int64.logor
                           (Int64.shift_left (Int64.of_int v6) 48)
                           (Int64.shift_left (Int64.of_int v7) 56)))))

    let read_float32 ic = read_int32 ic >>= fun x -> return (Int32.float_of_bits x)
    let read_float64 ic = read_int64 ic >>= fun x -> return (Int64.float_of_bits x)

    (* +-------------------------------------------------------------+
       | Writing numbers                                             |
       +-------------------------------------------------------------+ *)

    let set buffer ptr x = Lwt_bytes.unsafe_set buffer ptr (Char.unsafe_chr x)

    let write_int oc v =
      write_block_unsafe oc 4
        (fun buffer ptr ->
           set buffer (ptr + pos32_0) v;
           set buffer (ptr + pos32_1) (v lsr 8);
           set buffer (ptr + pos32_2) (v lsr 16);
           set buffer (ptr + pos32_3) (v asr 24);
           return ())

    let write_int16 oc v =
      write_block_unsafe oc 2
        (fun buffer ptr ->
           set buffer (ptr + pos16_0) v;
           set buffer (ptr + pos16_1) (v lsr 8);
           return ())

    let write_int32 oc v =
      write_block_unsafe oc 4
        (fun buffer ptr ->
           set buffer (ptr + pos32_0) (Int32.to_int v);
           set buffer (ptr + pos32_1) (Int32.to_int (Int32.shift_right v 8));
           set buffer (ptr + pos32_2) (Int32.to_int (Int32.shift_right v 16));
           set buffer (ptr + pos32_3) (Int32.to_int (Int32.shift_right v 24));
           return ())

    let write_int64 oc v =
      write_block_unsafe oc 8
        (fun buffer ptr ->
           set buffer (ptr + pos64_0) (Int64.to_int v);
           set buffer (ptr + pos64_1) (Int64.to_int (Int64.shift_right v 8));
           set buffer (ptr + pos64_2) (Int64.to_int (Int64.shift_right v 16));
           set buffer (ptr + pos64_3) (Int64.to_int (Int64.shift_right v 24));
           set buffer (ptr + pos64_4) (Int64.to_int (Int64.shift_right v 32));
           set buffer (ptr + pos64_5) (Int64.to_int (Int64.shift_right v 40));
           set buffer (ptr + pos64_6) (Int64.to_int (Int64.shift_right v 48));
           set buffer (ptr + pos64_7) (Int64.to_int (Int64.shift_right v 56));
           return ())

    let write_float32 oc v = write_int32 oc (Int32.bits_of_float v)
    let write_float64 oc v = write_int64 oc (Int64.bits_of_float v)
  end

  (* +---------------------------------------------------------------+
     | Random access                                                 |
     +---------------------------------------------------------------+ *)

  let do_seek seek pos =
    lwt offset = seek pos Unix.SEEK_SET in
    if offset <> pos then
      raise_lwt (Failure "Lwt_io.set_position: seek failed")
    else
      return ()

  let set_position ch pos = match ch.typ, ch.mode with
    | Type_normal(perform_io, seek), Output ->
        lwt () = flush_total ch in
        lwt () = do_seek seek pos in
        ch.offset <- pos;
        return ()
    | Type_normal(perform_io, seek), Input ->
        let current = Int64.sub ch.offset (Int64.of_int (ch.max - ch.ptr)) in
        if pos >= current && pos <= ch.offset then begin
          ch.ptr <- ch.max - (Int64.to_int (Int64.sub ch.offset pos));
          return ()
        end else begin
          lwt () = do_seek seek pos in
          ch.offset <- pos;
          ch.ptr <- 0;
          ch.max <- 0;
          return ()
        end
    | Type_bytes, _ ->
        if pos < 0L || pos > Int64.of_int ch.length then
          raise_lwt (Failure "Lwt_io.set_position: out of bounds")
        else begin
          ch.ptr <- Int64.to_int pos;
          return ()
        end

  let length ch = match ch.typ with
    | Type_normal(perform_io, seek) ->
        lwt len = seek 0L Unix.SEEK_END in
        lwt () = do_seek seek ch.offset in
        return len
    | Type_bytes ->
        return (Int64.of_int ch.length)
end

(* +-----------------------------------------------------------------+
   | Primitive operations                                            |
   +-----------------------------------------------------------------+ *)

let read_char wrapper =
  let channel = wrapper.channel in
  let ptr = channel.ptr in
  (* Speed-up in case a character is available in the buffer. It
     increases performances by 10x. *)
  if wrapper.state = Idle && ptr < channel.max then begin
    channel.ptr <- ptr + 1;
    return (Lwt_bytes.unsafe_get channel.buffer ptr)
  end else
    primitive Primitives.read_char wrapper

let read_char_opt wrapper =
  let channel = wrapper.channel in
  let ptr = channel.ptr in
  if wrapper.state = Idle && ptr < channel.max then begin
    channel.ptr <- ptr + 1;
    return (Some(Lwt_bytes.unsafe_get channel.buffer ptr))
  end else
    primitive Primitives.read_char_opt wrapper

let read_line ic = primitive Primitives.read_line ic
let read_line_opt ic = primitive Primitives.read_line_opt ic
let read ?count ic = primitive (fun ic -> Primitives.read count ic) ic
let read_into ic str ofs len = primitive (fun ic -> Primitives.read_into ic str ofs len) ic
let read_into_exactly ic str ofs len = primitive (fun ic -> Primitives.read_into_exactly ic str ofs len) ic
let read_value ic = primitive Primitives.read_value ic

let flush oc = primitive Primitives.flush oc

let write_char wrapper x =
  let channel = wrapper.channel in
  let ptr = channel.ptr in
  if wrapper.state = Idle && ptr < channel.max then begin
    channel.ptr <- ptr + 1;
    Lwt_bytes.unsafe_set channel.buffer ptr x;
    (* Fast launching of the auto flusher: *)
    if not channel.auto_flushing then begin
      channel.auto_flushing <- true;
      ignore (auto_flush channel);
      return ()
    end else
      return ()
  end else
    primitive (fun oc -> Primitives.write_char oc x) wrapper

let write oc str = primitive (fun oc -> Primitives.write oc str) oc
let write_line oc x = primitive (fun oc -> Primitives.write_line oc x) oc
let write_from oc str ofs len = primitive (fun oc -> Primitives.write_from oc str ofs len) oc
let write_from_exactly oc str ofs len = primitive (fun oc -> Primitives.write_from_exactly oc str ofs len) oc
let write_value oc ?flags x = primitive (fun oc -> Primitives.write_value oc ?flags x) oc

let block ch size f = primitive (fun ch -> Primitives.block ch size f) ch
let direct_access ch f = primitive (fun ch -> Primitives.direct_access ch f) ch

let set_position ch pos = primitive (fun ch -> Primitives.set_position ch pos) ch
let length ch = primitive Primitives.length ch

module type NumberIO = sig
  val read_int : input_channel -> int Lwt.t
  val read_int16 : input_channel -> int Lwt.t
  val read_int32 : input_channel -> int32 Lwt.t
  val read_int64 : input_channel -> int64 Lwt.t
  val read_float32 : input_channel -> float Lwt.t
  val read_float64 : input_channel -> float Lwt.t
  val write_int : output_channel -> int -> unit Lwt.t
  val write_int16 : output_channel -> int -> unit Lwt.t
  val write_int32 : output_channel -> int32 -> unit Lwt.t
  val write_int64 : output_channel -> int64 -> unit Lwt.t
  val write_float32 : output_channel -> float -> unit Lwt.t
  val write_float64 : output_channel -> float -> unit Lwt.t
end

module MakeNumberIO(ByteOrder : ByteOrder.S) =
struct
  module Primitives = Primitives.MakeNumberIO(ByteOrder)

  let read_int ic = primitive Primitives.read_int ic
  let read_int16 ic = primitive Primitives.read_int16 ic
  let read_int32 ic = primitive Primitives.read_int32 ic
  let read_int64 ic = primitive Primitives.read_int64 ic
  let read_float32 ic = primitive Primitives.read_float32 ic
  let read_float64 ic = primitive Primitives.read_float64 ic

  let write_int oc x = primitive (fun oc -> Primitives.write_int oc x) oc
  let write_int16 oc x = primitive (fun oc -> Primitives.write_int16 oc x) oc
  let write_int32 oc x = primitive (fun oc -> Primitives.write_int32 oc x) oc
  let write_int64 oc x = primitive (fun oc -> Primitives.write_int64 oc x) oc
  let write_float32 oc x = primitive (fun oc -> Primitives.write_float32 oc x) oc
  let write_float64 oc x = primitive (fun oc -> Primitives.write_float64 oc x) oc
end

module LE = MakeNumberIO(ByteOrder.LE)
module BE = MakeNumberIO(ByteOrder.BE)

type byte_order = Lwt_sys.byte_order = Little_endian | Big_endian
let system_byte_order = Lwt_sys.byte_order

include (val (match system_byte_order with
                | Little_endian -> (module LE : NumberIO)
                | Big_endian -> (module BE : NumberIO)) : NumberIO)

(* +-----------------------------------------------------------------+
   | Other                                                           |
   +-----------------------------------------------------------------+ *)

let read_chars ic = Lwt_stream.from (fun _ -> read_char_opt ic)
let write_chars oc chars = Lwt_stream.iter_s (fun char -> write_char oc char) chars
let read_lines ic = Lwt_stream.from (fun _ -> read_line_opt ic)
let write_lines oc lines = Lwt_stream.iter_s (fun line -> write_line oc line) lines

let zero =
  make
    ~mode:input
    ~buffer_size:min_buffer_size
    (fun str ofs len -> Lwt_bytes.fill str ofs len '\x00'; return len)

let null =
  make
    ~mode:output
    ~buffer_size:min_buffer_size
    (fun str ofs len -> return len)

(* Do not close standard ios on close, otherwise uncaught exceptions
   will not be printed *)
let stdin = of_fd ~mode:input Lwt_unix.stdin
let stdout = of_fd ~mode:output Lwt_unix.stdout
let stderr = of_fd ~mode:output Lwt_unix.stderr

let fprint oc txt = write oc txt
let fprintl oc txt = write_line oc txt
let fprintf oc fmt = Printf.ksprintf (fun txt -> write oc txt) fmt
let fprintlf oc fmt = Printf.ksprintf (fun txt -> write_line oc txt) fmt

let print txt = write stdout txt
let printl txt = write_line stdout txt
let printf fmt = Printf.ksprintf print fmt
let printlf fmt = Printf.ksprintf printl fmt

let eprint txt = write stderr txt
let eprintl txt = write_line stderr txt
let eprintf fmt = Printf.ksprintf eprint fmt
let eprintlf fmt = Printf.ksprintf eprintl fmt

let pipe ?buffer_size _ =
  let fd_r, fd_w = Lwt_unix.pipe () in
  (of_fd ?buffer_size ~mode:input fd_r, of_fd ?buffer_size ~mode:output fd_w)

type file_name = string

let open_file ?buffer_size ?flags ?perm ~mode filename =
  let flags = match flags, mode with
    | Some l, _ ->
        l
    | None, Input ->
        [Unix.O_RDONLY; Unix.O_NONBLOCK]
    | None, Output ->
        [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_NONBLOCK]
  and perm = match perm, mode with
    | Some p, _ ->
        p
    | None, Input ->
        0
    | None, Output ->
        0o666
  in
  lwt fd = Lwt_unix.openfile filename flags perm in
  return (of_fd ?buffer_size ~mode fd)

let with_file ?buffer_size ?flags ?perm ~mode filename f =
  lwt ic = open_file ?buffer_size ?flags ?perm ~mode filename in
  try_lwt
    f ic
  finally
    close ic

let file_length filename = with_file ~mode:input filename length

let open_connection ?buffer_size sockaddr =
  let fd = Lwt_unix.socket (Unix.domain_of_sockaddr sockaddr) Unix.SOCK_STREAM 0 in
  let close = lazy begin
    try_lwt
      Lwt_unix.shutdown fd Unix.SHUTDOWN_ALL;
      return ()
    with Unix.Unix_error(Unix.ENOTCONN, _, _) ->
      (* This may happen if the server closed the connection before us *)
      return ()
    finally
      Lwt_unix.close fd
  end in
  try_lwt
    lwt () = Lwt_unix.connect fd sockaddr in
    (try Lwt_unix.set_close_on_exec fd with Invalid_argument _ -> ());
    return (make ?buffer_size
              ~close:(fun _ -> Lazy.force close)
              ~mode:input (Lwt_bytes.read fd),
            make ?buffer_size
              ~close:(fun _ -> Lazy.force close)
              ~mode:output (Lwt_bytes.write fd))
  with exn ->
    lwt () = Lwt_unix.close fd in
    raise_lwt exn

let with_connection ?buffer_size sockaddr f =
  lwt ic, oc = open_connection sockaddr in
  try_lwt
    f (ic, oc)
  finally
    close ic <&> close oc

type server = {
  shutdown : unit Lazy.t;
}

let shutdown_server server = Lazy.force server.shutdown

let establish_server ?buffer_size ?(backlog=5) sockaddr f =
  let sock = Lwt_unix.socket (Unix.domain_of_sockaddr sockaddr) Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt sock Unix.SO_REUSEADDR true;
  Lwt_unix.bind sock sockaddr;
  Lwt_unix.listen sock backlog;
  let abort_waiter, abort_wakener = wait () in
  let abort_waiter = abort_waiter >> return `Shutdown in
  let rec loop () =
    pick [Lwt_unix.accept sock >|= (fun x -> `Accept x); abort_waiter] >>= function
      | `Accept(fd, addr) ->
          (try Lwt_unix.set_close_on_exec fd with Invalid_argument _ -> ());
          let close = lazy begin
            Lwt_unix.shutdown fd Unix.SHUTDOWN_ALL;
            Lwt_unix.close fd
          end in
          f (of_fd ?buffer_size ~mode:input ~close:(fun () -> Lazy.force close) fd,
             of_fd ?buffer_size ~mode:output ~close:(fun () -> Lazy.force close) fd);
          loop ()
      | `Shutdown ->
          lwt () = Lwt_unix.close sock in
          match sockaddr with
            | Unix.ADDR_UNIX path when path <> "" && path.[0] <> '\x00' ->
                Unix.unlink path;
                return ()
            | _ ->
                return ()
  in
  ignore (loop ());
  { shutdown = lazy(wakeup abort_wakener `Shutdown) }

let ignore_close ch =
  ignore (close ch)

let make_stream f lazy_ic =
  let lazy_ic =
    lazy(lwt ic = Lazy.force lazy_ic in
         Gc.finalise ignore_close ic;
         return ic)
  in
  Lwt_stream.from (fun _ ->
                     lwt ic = Lazy.force lazy_ic in
                     lwt x = f ic in
                     if x = None then
                       lwt () = close ic in
                       return x
                     else
                       return x)

let lines_of_file filename =
  make_stream read_line_opt (lazy(open_file ~mode:input filename))

let lines_to_file filename lines =
  with_file ~mode:output filename (fun oc -> write_lines oc lines)

let chars_of_file filename =
  make_stream read_char_opt (lazy(open_file ~mode:input filename))

let chars_to_file filename chars =
  with_file ~mode:output filename (fun oc -> write_chars oc chars)

let hexdump_stream oc stream = write_lines oc (Lwt_stream.hexdump stream)
let hexdump oc buf = hexdump_stream oc (Lwt_stream.of_string buf)

let set_default_buffer_size size =
  check_buffer_size "set_default_buffer_size" size;
  default_buffer_size := size
let default_buffer_size _ = !default_buffer_size
