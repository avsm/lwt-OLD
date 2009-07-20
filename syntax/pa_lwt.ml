(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Pa_lwt
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

open Camlp4
open Camlp4.PreCast
open Syntax

(* Generate the catching function from a macth-case.

   The main work of this functions is to add a case:

   {[
     | exn -> fail exn
   ]}

   when there is not already one. *)
let gen_catch mc =
  (* Does the match case have a rule of the form "| e -> ..." ? *)
  let rec have_default = function
    | <:match_case< $a$ | $b$ >> -> have_default a || have_default b
    | <:match_case< _ -> $_$ >>
    | <:match_case< $lid:_$ -> $_$ >> -> true
    | _ -> false
  in
  if have_default mc then
    mc
  else
    let _loc = Ast.loc_of_match_case mc in
    <:match_case< $mc$ | exn -> Lwt.fail exn >>

let gen_binding l =
  let rec aux n = function
    | [] ->
        assert false
    | [(_loc, p, e)] ->
        <:binding< $lid:"__pa_lwt_" ^ string_of_int n$ = $e$ >>
    | (_loc, p, e) :: l ->
        <:binding< $lid:"__pa_lwt_" ^ string_of_int n$ = $e$ and $aux (n + 1) l$ >>
  in
  aux 0 l

let gen_bind l e =
  let rec aux n = function
    | [] -> e
    | (_loc, p, e) :: l ->
        <:expr< Lwt.bind $lid:"__pa_lwt_" ^ string_of_int n$ (fun $p$ -> $aux (n + 1) l$) >>
  in
  aux 0 l

EXTEND Gram
  GLOBAL: expr;

    cases:
      [ [ "with"; c = match_case -> Some(gen_catch c)
        | -> None ] ];

    finally:
      [ [ "finally"; f = sequence -> Some f
        | -> None ] ];

    letb_binding:
      [ [ b1 = SELF; "and"; b2 = SELF -> b1 @ b2
        | p = patt; "="; e = expr -> [(_loc, p, e)]
        ] ];

    for_scheme:
      [ [ "="; s = sequence; "to"; e = sequence ->
            `CountTo(s, e)
        | "="; s = sequence; "downto"; e = sequence ->
            `CountDownTo(s, e)
        | "in"; e = sequence ->
            `IterOver(e) ] ];

    expr: LEVEL "top"
      [ [ "try_lwt"; e = expr LEVEL ";"; c = cases; f = finally ->
            begin match c, f with
              | None, None ->
                  <:expr< Lwt.catch (fun _ -> $e$) (fun e -> Lwt.fail e) >>
              | Some c, None ->
                  <:expr< Lwt.catch (fun _ -> $e$) (function $c$) >>
              | None, Some f ->
                  <:expr< Lwt.finalize (fun _ -> $e$) (fun _ -> (begin $f$ end)) >>
              | Some c, Some f ->
                  <:expr< Lwt.try_bind (fun _ -> $e$)
                            (fun __pa_lwt_x -> Lwt.bind (begin $f$ end) (fun () -> Lwt.return __pa_lwt_x))
                            (fun __pa_lwt_e -> Lwt.bind (begin $f$ end) (fun () -> match __pa_lwt_e with $c$))
                  >>
            end

        | "lwt"; l = letb_binding; "in"; e = expr LEVEL ";" ->
            <:expr< let $gen_binding l$ in $gen_bind l e$ >>

        | "for_lwt"; p = patt; scheme = for_scheme; "do"; seq = do_sequence ->
            (match p, scheme with
               | <:patt< $lid:id$ >>, `CountTo(s, e) ->
                   <:expr< let __pa_lwt_max = $e$ in
                           let rec __pa_lwt_loop $lid:id$ =
                             if $lid:id$ > __pa_lwt_max then
                               Lwt.return ()
                             else
                               Lwt.bind (begin $seq$ end) (fun () -> __pa_lwt_loop ($lid:id$ + 1))
                           in
                           __pa_lwt_loop $s$
                   >>

               | <:patt< $lid:id$ >>, `CountDownTo(s, e) ->
                   <:expr< let __pa_lwt_min = $e$ in
                           let rec __pa_lwt_loop $lid:id$ =
                             if $lid:id$ < __pa_lwt_min then
                               Lwt.return ()
                             else
                               Lwt.bind (begin $seq$ end) (fun () -> __pa_lwt_loop ($lid:id$ - 1))
                           in
                           __pa_lwt_loop $s$
                   >>

               | p, `IterOver(e) ->
                   <:expr< Lwt_stream.iter_s (fun $p$ -> $seq$) $e$ >>

               | _ ->
                   Loc.raise _loc (Failure "syntax error"))
        ] ];
END

(* Replace the anonymous bind [x >> y] by [x >>= fun _ -> y] *)
let map_anonymous_bind = object
  inherit Ast.map as super
  method expr e = match super#expr e with
    | <:expr@_loc< $lid:f$ $a$ $b$ >> when f = ">>" -> <:expr< bind $a$ (fun _ -> $b$) >>
    | e -> e
end

let _ =
  AstFilters.register_str_item_filter map_anonymous_bind#str_item;
  AstFilters.register_topphrase_filter map_anonymous_bind#str_item
