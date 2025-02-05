(*
   Various utilities to deal with git projects.

   Tests are in Unit_semgrepignore.ml
*)
open Fpath_.Operators
module Log = Log_git_wrapper.Log

type scanning_root_info = { project_root : Rfpath.t; inproject_path : Ppath.t }

(* nongit = not identified as being in a git project or any other well-defined
   project. *)
let get_project_root_for_nongit_file (path : Fpath.t) =
  if Fpath.is_rel path then Rfpath.getcwd ()
  else Rfpath.of_fpath_exn (Fpath.parent path)

let force_project_root ?(project_root : Rfpath.t option) (path : Fpath.t) =
  let project_root =
    match project_root with
    | None -> get_project_root_for_nongit_file path
    | Some x -> x
  in
  Log.debug (fun m ->
      m "project_root=%s path=%s" (Rfpath.show project_root)
        (Fpath.to_string path));
  match Ppath.in_project ~root:project_root path with
  | Ok inproject_path -> { project_root; inproject_path }
  | Error msg -> failwith msg

let find_any_project_root ?fallback_root ?force_root (fpath : Fpath.t) =
  Log.debug (fun m ->
      m "find_any_project_root: fallback_root=%s force_root=%s %s"
        (Logs_.option Rfpath.show fallback_root)
        (Logs_.option (fun _ -> "_") force_root)
        !!fpath);
  match force_root with
  | Some (kind, project_root) ->
      let scanning_root_info = force_project_root ~project_root fpath in
      (kind, scanning_root_info)
  | None -> (
      match Git_wrapper.get_project_root_for_file_or_files_in_dir fpath with
      | Some project_root ->
          (* note: this project_root returned by git appears to be
             a physical path already. *)
          let project_root = Rfpath.of_fpath_exn project_root in
          let inproject_path =
            match Ppath.in_project ~root:project_root fpath with
            | Ok x -> x
            | Error msg -> failwith msg
          in
          (Project.Git_project, { project_root; inproject_path })
      | None ->
          let scanning_root_info =
            force_project_root ?project_root:fallback_root fpath
          in
          (Project.Other_project, scanning_root_info))
