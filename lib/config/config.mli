(** Configuration types, decoding, and partial semantic validation. *)

include module type of Config_types
module Diagnostic : module type of Diagnostic
module Decode : module type of Decode
module Validate : module type of Validate
