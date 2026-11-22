val run :
  image:string ->
  string list ->
  (Deco.Process.result, Deco.Process.error) result

type status = {
  begin_stage : unit -> unit;
  tick : unit -> unit;
  finish : bool -> unit;
}

val status : label:string -> image:string -> status

type runners = {
  execute :
    Deco.Process.output ->
    string list ->
    (Deco.Process.result, Deco.Process.error) result;
      (** Inherited output is a build, shown with {!run}. Captured [create] and
          [start] commands begin the status stage, so nothing is drawn between a
          build and those commands. *)
  read_many :
    string list list -> (Deco.Process.result, Deco.Process.error) result list;
      (** Concurrent read-only commands, forwarding signals. *)
  hook : string list -> (Deco.Process.result, Deco.Process.error) result;
      (** Run a lifecycle hook with inherited output, forwarding signals. The
          status line is closed as complete first. *)
  close : bool -> unit;
      (** Close the status line. Closing an already closed status line does
          nothing. *)
}
(** Process runners for commands that build an image and then create and start a
    container, such as [assemble] and [refresh]. *)

val runners : label:string -> image:string -> runners
