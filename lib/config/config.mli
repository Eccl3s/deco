(** Configuration types, decoding, partial validation, and default resolution.
*)

include module type of Config_types
module Diagnostic : module type of Diagnostic
module Decode : module type of Decode
module Validate : module type of Validate
module Effective : module type of Effective
module Resolve : module type of Resolve
