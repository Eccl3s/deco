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
