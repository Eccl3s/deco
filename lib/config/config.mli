(** Configuration types and strict TOML decoding. *)

include module type of Config_types
module Decode : module type of Decode
