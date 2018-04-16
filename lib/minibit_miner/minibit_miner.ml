open Core
open Async

module Make
  (Inputs : Protocols.Minibit_pow.Inputs_intf)
  (Transition_with_witness : Minibit.Transition_with_witness_intf
   with type transition := Inputs.Transition.t
    and type transaction_with_valid_signature := Inputs.Transaction.With_valid_signature.t)
  (Transaction_pool : Minibit.Transaction_pool_intf
   with type transaction_with_valid_signature := Inputs.Transaction.With_valid_signature.t)
  (Bundle : sig
     open Inputs

     type t

     val create : Ledger.t -> Transaction.With_valid_signature.t list -> t

     val cancel : t -> unit

     val target_hash : t -> Ledger.t Hash.t

     val result : t -> Ledger_proof.t Deferred.Option.t
   end)
  : Minibit.Miner_intf
    with type 'a hash := 'a Inputs.Hash.t
     and type ledger := Inputs.Ledger.t
     and type state := Inputs.State.t
     and type transition_with_witness := Transition_with_witness.t
     and type transaction_pool := Transaction_pool.t
= struct
  open Inputs

  module Hashing_result : sig
    type t

    val create : State.t -> next_ledger_hash:Ledger.t Hash.t -> t

    val result : t -> [ `Ok of State.t * Nonce.t | `Cancelled ] Deferred.t

    val cancel : t -> unit
  end = struct
    type t =
      { cancelled : bool ref
      ; result : [ `Ok of State.t * Nonce.t | `Cancelled ] Deferred.t
      }

    let result t = t.result

    let cancel t = t.cancelled := true

    let find_block (previous : State.t) ~(next_ledger_hash : Ledger.t Hash.t)
      : (State.t * Nonce.t) option =
      let iterations = 10 in

      let now = Time.now () in
      let difficulty = previous.next_difficulty in
      let next_difficulty =
        Difficulty.next difficulty ~last:previous.timestamp ~this:now
      in
      let next_state : State.t =
        { next_difficulty
        ; previous_state_hash = Hash.digest previous
        ; ledger_hash = next_ledger_hash
        ; timestamp = now
        ; strength = Strength.increase previous.strength difficulty
        }
      in
      let nonce0 = Nonce.random () in
      let rec go nonce i =
        if i = iterations
        then None
        else
          let hash = Hash.digest (next_state, nonce) in
          if Difficulty.meets difficulty hash
          then Some (next_state, nonce)
          else go (Nonce.succ nonce) (i + 1)
      in
      go nonce0 0
    ;;

    let create previous ~next_ledger_hash =
      let cancelled = ref false in
      let rec go () =
        if !cancelled
        then return `Cancelled
        else begin
          match find_block previous ~next_ledger_hash with
          | None ->
            let%bind () = after (sec 0.01) in
            go ()
          | Some (state, nonce) ->
            return (`Ok (state, nonce))
        end
      in
      { cancelled; result = go () }
  end

  module Bundle_result : sig
    type t

    val transactions : t -> Transaction.With_valid_signature.t list 

    val target_hash : t -> Ledger.t Hash.t

    val result : t -> (Ledger_proof.t * Transaction.With_valid_signature.t list) option Deferred.t

    val cancel : t -> unit

    val create : Ledger.t -> Transaction.With_valid_signature.t list -> t
  end = struct
    type t =
      { bundle : Bundle.t
      ; transactions : Transaction.With_valid_signature.t list
      }
    [@@deriving fields]

    let target_hash t = Bundle.target_hash t.bundle

    let cancel t = Bundle.cancel t.bundle

    let result t =
      Deferred.Option.map (Bundle.result t.bundle)
        ~f:(fun proof -> (proof, t.transactions))

    let create ledger transactions =
      let bundle = Bundle.create ledger transactions in
      { bundle; transactions }
  end

  module Mining_result : sig
    type t

    val cancel : t -> unit

    val create
      : state:State.t
      -> ledger:Ledger.t
      -> transactions:Transaction.With_valid_signature.t list
      -> t

    val transactions : t -> Transaction.With_valid_signature.t list

    val result : t -> Transition_with_witness.t Deferred.Or_error.t
  end = struct
    type t =
      { hashing_result : Hashing_result.t
      ; bundle_result : Bundle_result.t
      ; cancellation : unit Ivar.t
      ; result : Transition_with_witness.t Deferred.Or_error.t
      }
    [@@deriving fields]

    let cancel t =
      Hashing_result.cancel t.hashing_result;
      Bundle_result.cancel t.bundle_result;
      Ivar.fill_if_empty t.cancellation ()
    ;;

    let transactions t = Bundle_result.transactions t.bundle_result

    let create ~state ~ledger ~transactions =
      let bundle_result = Bundle_result.create ledger transactions in
      let next_ledger_hash = Bundle_result.target_hash bundle_result in
      let hashing_result = Hashing_result.create state ~next_ledger_hash in
      let cancellation = Ivar.create () in
      (* Someday: If bundle finishes first you can stuff more transactions in the bundle *)
      let result =
        let result =
          let%map hashing_result = Hashing_result.result hashing_result
          and bundle_result = Bundle_result.result bundle_result
          in
          match hashing_result, bundle_result with
          | `Ok (new_state, nonce), Some (ledger_proof, ts) ->
            Ok
              { Transition_with_witness.transition =
                { ledger_hash = next_ledger_hash
                ; ledger_proof = ledger_proof
                ; timestamp = new_state.timestamp
                ; nonce
                }
              ; transactions
              }
          | `Cancelled, _ -> Or_error.error_string "Mining cancelled"
          | _, None       -> Or_error.error_string "Transaction bundling failed"
        in
        Deferred.any
          [ (Ivar.read cancellation >>| fun () -> Or_error.error_string "Mining cancelled")
          ; result
          ]
      in
      { bundle_result
      ; hashing_result
      ; result
      ; cancellation
      }
  end

  module Tip = struct
    type t =
      { state : State.t
      ; ledger : Ledger.t
      ; transaction_pool : Transaction_pool.t
      }
  end

  type change =
    | Tip_change of Tip.t

  let transactions_per_bundle = 10

  type state =
    { tip : Tip.t
    ; result : Mining_result.t
    }

  type t =
    { transitions : Transition_with_witness.t Linear_pipe.Reader.t
    }
  [@@deriving fields]

  let transition_capacity = 64

  let create ~parent_log ~change_feeder
    =
    let logger = Logger.extend parent_log [ "module", Atom __MODULE__ ] in
    let (r, w) = Linear_pipe.create () in
    let write_result = function
      | Ok t ->
        Linear_pipe.write_or_exn ~capacity:transition_capacity w r t
      | Error e ->
        Logger.error logger "%s\n" Error.(to_string_hum (tag e ~tag:"miner"))
    in
    let create_result { Tip.state; transaction_pool; ledger } =
      let result =
        Mining_result.create
          ~state
          ~transactions:(Transaction_pool.get transaction_pool transactions_per_bundle)
          ~ledger
      in
      upon (Mining_result.result result) write_result;
      result
    in
    don't_wait_for begin
      match%bind Pipe.read change_feeder.Linear_pipe.Reader.pipe with
      | `Eof -> failwith "change_feeder was empty"
      | `Ok (Tip_change initial_tip) ->
        let state0 =
          { result = create_result initial_tip
          ; tip = initial_tip
          }
        in
        Linear_pipe.fold change_feeder ~init:state0 ~f:(fun s u ->
          match u with
          | Tip_change tip ->
            Mining_result.cancel s.result;
            let result = create_result tip in
            return { result; tip })
        >>| ignore
    end;
    { transitions = r }
end