(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

(* NBD client library *)

let nbd_cmd_read = 0l
let nbd_cmd_write = 1l
let nbd_cmd_disc = 2l
let nbd_cmd_flush = 3l
let nbd_cmd_trim = 4l

let nbd_request_magic = 0x25609513l
let nbd_reply_magic = 0x67446698l

let nbd_flag_has_flags = 1
let nbd_flag_read_only = 2
let nbd_flag_send_flush = 4
let nbd_flag_send_fua = 8
let nbd_flag_rotational = 16
let nbd_flag_send_trim = 32

module Flag = struct
  type t =
    | Read_only
    | Send_flush
    | Send_fua
    | Rotational
    | Send_trim

  let to_string = function
  | Read_only -> "Read_only"
  | Send_flush -> "Send_flush"
  | Send_fua -> "Send_fua"
  | Rotational -> "Rotational"
  | Send_trim -> "Send_trim"

  let of_int32 x =
    let flags = Int32.to_int x in
    let is_set i mask = i land mask = mask in
      List.map snd 
        (List.filter (fun (mask,_) -> is_set flags mask)
          [ nbd_flag_read_only, Read_only;
            nbd_flag_send_flush, Send_flush;
            nbd_flag_send_fua, Send_fua;
            nbd_flag_rotational, Rotational;
            nbd_flag_send_trim, Send_trim; ])

  let to_int32 flags =
    let one = function
      | Read_only -> nbd_flag_read_only
      | Send_flush -> nbd_flag_send_flush
      | Send_fua -> nbd_flag_send_fua
      | Rotational -> nbd_flag_rotational
      | Send_trim -> nbd_flag_send_trim in
    Int32.of_int (List.fold_left (lor) 0 (List.map one flags))
end

module Command = struct
  type t =
    | Read
    | Write
    | Disc
    | Flush
    | Trim
    | Unknown of int32

  let to_string = function
  | Read -> "Read"
  | Write -> "Write"
  | Disc -> "Disc"
  | Flush -> "Flush"
  | Trim -> "Trim"
  | Unknown code -> "Unknown " ^ (Int32.to_string code)

  let of_int32 = function 
  | 0l -> Read 
  | 1l -> Write 
  | 2l -> Disc 
  | 3l -> Flush 
  | 4l -> Trim
  | c  -> Unknown c

  let to_int32 = function 
  | Read -> 0l 
  | Write -> 1l 
  | Disc -> 2l 
  | Flush -> 3l 
  | Trim -> 4l
  | Unknown c -> c

end

module Negotiate = struct
  type t = {
    size: int64;
    flags: Flag.t list;
  }

  let to_string t =
    Printf.sprintf "{ size = %Ld; flags = [ %s ] }"
    t.size (String.concat ", " (List.map Flag.to_string t.flags))

  cstruct t {
    uint8_t passwd[8];
    uint64_t magic;
    uint64_t size;
    uint32_t flags;
    uint8_t padding[124]
  } as big_endian

  let sizeof = sizeof_t

  let expected_passwd = "NBDMAGIC"

  let opts_magic = 0x49484156454F5054L
  let cliserv_magic = 0x00420281861253L

  let marshal buf t =
    set_t_passwd expected_passwd 0 buf;
    set_t_magic buf cliserv_magic;
    set_t_size buf t.size;
    set_t_flags buf (Flag.to_int32 t.flags)

  let unmarshal buf =
    let open Nbd_result in
    let passwd = Cstruct.to_string (get_t_passwd buf) in
    if passwd <> expected_passwd
    then `Error (Failure "Bad magic in negotiate")
    else
      let magic = get_t_magic buf in
      if magic =opts_magic
      then `Error (Failure "Unhandled opts_magic")
      else if magic <> cliserv_magic
      then `Error (Failure (Printf.sprintf "Bad magic; expected %Ld got %Ld" cliserv_magic magic))
      else
        let size = get_t_size buf in
        let flags = Flag.of_int32 (get_t_flags buf) in
        return { size; flags }
end

module Request = struct
  type t = {
    ty : Command.t;
    handle : int64;
    from : int64;
    len : int32
  }

  let to_string t =
    Printf.sprintf "{ Command = %s; handle = %Ld; from = %Ld; len = %ld }"
      (Command.to_string t.ty) t.handle t.from t.len

  cstruct t {
    uint32_t magic;
    uint32_t ty;
    uint64_t handle;
    uint64_t from;
    uint32_t len
  } as big_endian

  let unmarshal (buf: Cstruct.t) =
    let open Nbd_result in
    let magic = get_t_magic buf in
    ( if nbd_request_magic <> magic
      then fail (Failure (Printf.sprintf "Bad request magic: expected %ld, got %ld" magic nbd_request_magic))
      else return () ) >>= fun () ->
    let ty = Command.of_int32 (get_t_ty buf) in
    let handle = get_t_handle buf in
    let from = get_t_from buf in
    let len = get_t_len buf in
    return { ty; handle; from; len }

  let sizeof = sizeof_t

  let marshal (buf: Cstruct.t) t =
    set_t_magic buf nbd_request_magic;
    set_t_ty buf (Command.to_int32 t.ty);
    set_t_handle buf t.handle;
    set_t_from buf t.from;
    set_t_len buf t.len
end
	
module Reply = struct
  type t = {
    error : int32;
    handle : int64;
  }

  let to_string t =
    Printf.sprintf "{ handle = %Ld; error = %ld }" t.handle t.error

  cstruct t {
    uint32_t magic;
    uint32_t error;
    uint64_t handle
  } as big_endian

  let unmarshal (buf: Cstruct.t) =
    let open Nbd_result in
    let magic = get_t_magic buf in
    ( if nbd_reply_magic <> magic
      then fail (Failure (Printf.sprintf "Bad reply magic: expected %ld, got %ld" magic nbd_reply_magic))
      else return () ) >>= fun () ->
    let error = get_t_error buf in
    let handle = get_t_handle buf in
    return { error; handle }

  let sizeof = sizeof_t

  let marshal (buf: Cstruct.t) t =
    set_t_magic buf nbd_reply_magic;
    set_t_error buf t.error;
    set_t_handle buf t.handle
end
