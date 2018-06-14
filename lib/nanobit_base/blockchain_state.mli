open Core_kernel
open Snark_params
open Tick

type ('target, 'state_hash, 'ledger_hash, 'strength, 'time) t_ =
  { next_difficulty: 'target
  ; previous_state_hash: 'state_hash
  ; ledger_hash: 'ledger_hash
  ; strength: 'strength
  ; timestamp: 'time }
[@@deriving fields]

type t = (Target.t, State_hash.t, Ledger_hash.t, Strength.t, Block_time.t) t_
[@@deriving sexp, eq]

module Stable : sig
  module V1 : sig
    type nonrec ('a, 'b, 'c, 'd, 'e) t_ = ('a, 'b, 'c, 'd, 'e) t_ =
      { next_difficulty: 'a
      ; previous_state_hash: 'b
      ; ledger_hash: 'c
      ; strength: 'd
      ; timestamp: 'e }
    [@@deriving bin_io, sexp, eq]

    type nonrec t =
      ( Target.Stable.V1.t
      , State_hash.Stable.V1.t
      , Ledger_hash.Stable.V1.t
      , Strength.Stable.V1.t
      , Block_time.Stable.V1.t )
      t_
    [@@deriving bin_io, sexp, eq]
  end
end

include Snarkable.S
        with type var =
                    ( Target.Unpacked.var
                    , State_hash.var
                    , Ledger_hash.var
                    , Strength.Unpacked.var
                    , Block_time.Unpacked.var )
                    t_
         and type value = t

module Hash = State_hash

val length_in_bits : int

val fold : t -> init:'acc -> f:('acc -> bool -> 'acc) -> 'acc

val to_bits : var -> (Boolean.var list, _) Checked.t

val to_bits_unchecked : t -> bool list

val hash : t -> Hash.t