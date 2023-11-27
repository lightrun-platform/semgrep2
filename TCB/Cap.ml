(**************************************************************************)
(* Prelude *)
(**************************************************************************)
(* Capabilities implemented as simple abstract types and explicit
 * parameters ("Lambda the ultimate security tool").
 *
 * references:
 *  - https://en.wikipedia.org/wiki/Capability-based_security
 *  - "Computer Systems Security Session 6: Capabilities" accessible at
 *    https://www.youtube.com/watch?v=TQhmua7Z2cY
 *    by Zeldovich and Mickens, Fall 2014. Good introduction.
 *
 * related work:
 *  - EIO capabilities for network, fs, io, etc.
 *    see especially Eio_unix.Stdenv.base, and also Thomas's blog post
 *    https://roscidus.com/blog/blog/2023/04/26/lambda-capabilities/
 *  - TODO Android's permissions? iphone permissions?
 *  - TODO lots of related work
 *
 * alt:
 *  - effect system, but not ready yet for OCaml
 *  - semgrep rules, but this would be more of a blacklist approach whereas
 *    here it is more a whitelist approach
 *
 * LATER:
 *  - exn (ability to thrown exn)
 *  - comparison
 *  - refs
 *
 * Assumed capabilities:
 *  - use RAM (see Memory_limit.ml for some limits)
 *  - use CPU (see Time_limit.ml for some limits)
 *)

(**************************************************************************)
(* Network *)
(**************************************************************************)

(* TODO: sub capabilities: host, url, ports, get vs post *)
module Network = struct
  type t = unit
end

(**************************************************************************)
(* FS *)
(**************************************************************************)

(* TODO: read vs write, specific dir (in_chan or out_chan of opened dir *)
module FS = struct
  type root_r = unit
  type root_w = unit
  type cwd_r = unit
  type cwd_w = unit
  type tmp_r = unit
  type tmp_w = unit
end

(**************************************************************************)
(* Files *)
(**************************************************************************)

module File = struct
  (* TODO: embed also the filename in it? useful for
   * error reporting.
   * TODO? inout_channel?
   *)
  type in_channel = Stdlib.in_channel
  type out_channel = Stdlib.out_channel
end

(**************************************************************************)
(* Exec *)
(**************************************************************************)

(* TODO: sub capabilities exec a particular program 'git_cmd Exec.t' *)
module Exec = struct
  type t = unit
end

(**************************************************************************)
(* Process *)
(**************************************************************************)

module Process = struct
  (* basic stuff *)
  type argv = unit
  type env = unit

  (* advanced stuff
   * TODO: subtypes, like timeout signal very important
   *)
  type signal = unit
  type exit = unit
  type fork = unit
  type thread = unit
  type domain = unit
end

(**************************************************************************)
(* Console *)
(**************************************************************************)

(* alt: could be part of Process *)
module Console = struct
  type stdin = unit
  type stdout = unit
  (* no stderr, ambient authority *)
end

(**************************************************************************)
(* Misc *)
(**************************************************************************)

module Misc = struct
  (* supposedely important for side-channel attack *)
  type time = unit

  (* useful to be sure the program is deterministic and is not calling
   * any random generator functions.
   *)
  type random = unit
end

(**************************************************************************)
(* The powerbox *)
(**************************************************************************)
(* Entry point giving all the authories, a.k.a. the "Powerbox"
 *
 * references:
 *  - "How Emily Tamed the Caml"
 *     https://www.hpl.hp.com/techreports/2006/HPL-2006-116.html
 *  - "Lambda Capabilities"
 *     https://roscidus.com/blog/blog/2023/04/26/lambda-capabilities/
 *  - TODO: "A Security Kernel Based on the Lambda-Calculus", Jonathan A. Rees,
 *    https://dspace.mit.edu/handle/1721.1/5944
 *  - TODO: "Effects, Capabilities, and Boxes"
 *    https://dl.acm.org/doi/pdf/10.1145/3527320
 *)

(* alt: called "Stdenv.Base.env" in EIO *)
type powerbox = {
  process : process_powerbox;
  fs : fs_powerbox;
  exec : Exec.t;
  network : Network.t;
  misc : misc_powerbox;
}

and fs_powerbox = {
  root_r : FS.root_r;
  root_w : FS.root_w;
  cwd_r : FS.cwd_r;
  cwd_w : FS.cwd_w;
  tmp_r : FS.tmp_r;
  tmp_w : FS.tmp_w;
}

and process_powerbox = {
  stdin : Console.stdin;
  stdout : Console.stdout;
  argv : Process.argv;
  env : Process.env;
  (* advanced stuff *)
  signal : Process.signal;
  fork : Process.fork;
  exit : Process.exit;
  domain : Process.domain;
  thread : Process.thread;
}

and misc_powerbox = { time : Misc.time; random : Misc.random }

(* "subtypes" of powerbox *)
type no_network = {
  process : process_powerbox;
  fs : fs_powerbox;
  exec : Exec.t;
}

type no_exec = { process : process_powerbox; fs : fs_powerbox }
type no_fs = { process : process_powerbox }

type no_concurrency = {
  stdin : Console.stdin;
  stdout : Console.stdout;
  argv : Process.argv;
  env : Process.env;
}

type nocap = unit

let fs_powerbox =
  { root_r = (); root_w = (); cwd_r = (); cwd_w = (); tmp_r = (); tmp_w = () }

let process_powerbox =
  {
    stdin = ();
    stdout = ();
    argv = ();
    env = ();
    signal = ();
    fork = ();
    exit = ();
    domain = ();
    thread = ();
  }

let misc_powerbox = { time = (); random = () }

let powerbox =
  {
    process = process_powerbox;
    fs = fs_powerbox;
    exec = ();
    network = ();
    misc = misc_powerbox;
  }

(**************************************************************************)
(* Entry point *)
(**************************************************************************)

let already_called_main = ref false

(* TODO: in addition to the dynamic check below, we could also
 * write a semgrep rule to forbid any call to Cap.main() except
 * in Main.ml (via a nosemgrep or paths: exclude:)
 *)
let main (f : powerbox -> 'a) : 'a =
  (* can't cheat :) can't nest them *)
  if !already_called_main then failwith "Cap.main() already called"
  else (
    already_called_main := true;
    f powerbox)
