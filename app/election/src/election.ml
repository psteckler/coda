open Core
open Camlsnark
open Impl
open Import
open Let_syntax

(* Election day! The time has come for citizens to cast their ballots for
   pizza toppings: will it be pepperoni? Or will mushroom win the day?

   But there is a slight problem:
   Reports suggest that there have been attempts to hack the software that
   tabulates votes and determines the winner. As such, the government has decided
   that the election results should be accompanied by a proof of their correctness.
   The scheme is as follows:

   Let $H$ be a hash function and say there are $n$ voters.
   - Each voter $i$ will provide the government with their vote $v_i$ along with
     a random nonce $x_i$ for a commitment $h_i = H(x_i, v_i)$.
   - The government will compute the result of the election, either pepperoni or mushroom.
   - The government will prove in zero knowledge the following statement:
      Exposing the commitments $h_1, \dots, h_n$ and the winner $w$,
      there exist $(x_1, v_1), \dots, (x_n, v_n)$ such that
      - For each $i$, $H(x_i, v_i) = h_i$.
      - if the number of votes for Pepperoni is greater than n / 2, $w$ is Pepperoni,
        otherwise, $w$ is Mushroom.

   In plain English, they'll prove "I know votes corresponding to the commitments $h_i$
   such that taking the majority of those votes results in winner $w$".
*)

(* First we declare the type of "votes" and call a library functor [Enumerable] to
   make it possible to refer to values of type [Vote.t] in checked computations. *)
module Vote = struct
  module T = struct
    type t =
      | Pepperoni
      | Mushroom
    [@@deriving enum]
  end
  include T
  include Enumerable(T)
end

module Ballot = struct
  module Opened = struct
    module Nonce = Field

    (* An opened ballot is a nonce along with a vote. *)
    type t = Nonce.t * Vote.t
    type var = Nonce.var * Vote.var
    (* A [typ] is a kind of specification of a type of data which makes it possible
       to use values of that type inside checked computations. In a future version of
       the library, [typ]s will be derived automatically with a ppx extension.
    *)
    let typ = Typ.(Nonce.typ * Vote.typ)

    let to_bits (nonce, vote) =
      Nonce.to_bits nonce @ Vote.to_bits vote

(* This is our first explicit example of a checked computation. It simply says that to
   convert an opened ballot into bits, one converts the nonce and the vote into bits and
   concatenates them. Behind the scenes, this function would set up all the constraints
   necessary to certify the correctness of this computation with a snark. *)
    let var_to_bits (nonce, vote) =
      let%map nonce_bits = Nonce.var_to_bits nonce
      and vote_bits = Vote.var_to_bits vote
      in
      nonce_bits @ vote_bits

    let create vote : t = (Field.random (), vote)
  end

  (* A closed ballot is simply a hash *)
  module Closed = Hash
end

(* Here we have a checked computation for "closing" an opened ballot. In other words,
   turning the ballot into a commitment. *)
let close_ballot_var (ballot : Ballot.Opened.var) =
  let%bind bs = Ballot.Opened.var_to_bits ballot in
  Hash.hash_var bs

let close_ballot (ballot : Ballot.Opened.t) =
  Hash.hash (Ballot.Opened.to_bits ballot)

(* Checked computations in Snarky are allowed to ask for help.
   This adds a new kind of request a checked computation can make: [Open_ballot i]
   is a request for the opened ballot corresponding to voter [i].
*)
type _ Request.t +=
  | Open_ballot : int -> Ballot.Opened.t Request.t

(* Here we write a checked function [open_ballot], which given a voter index [i]
   and a closed ballot (i.e., a commitment) [closed], produces the corresponding
   opened ballot (i.e., the value committed to).
   
   This seems odd, since commitments are supposed to be hiding. That is, there should
   be no way to compute the committed value from the commitment which this checked function
   is supposed to do. The trick is that checked computations are allowed to ask for help
   and then verify that the help was useful. In this case, we [request] for someone out there
   to provide us with an opening to our commitment, and then check that it is indeed a
   correct opening of our closed ballot, before returning it as the result of the function. *)
let open_ballot i (closed : Ballot.Closed.var) =
  let%bind ((_, vote) as opened) =
    request Ballot.Opened.typ (Open_ballot i)
  in
  let%bind () =
    let%bind implied_closed = close_ballot_var opened in
    Ballot.Closed.assert_equal implied_closed closed
  in
  return vote

(* Now we write a simple checked function counting up all the votes for pepperoni in a
   given list of votes. *)
let count_pepperoni_votes vs =
  let open Number in
  let rec go pepperoni_total vs =
    match vs with
    | [] -> return pepperoni_total
    | v :: vs' ->
      let%bind new_total =
        let%bind pepperoni_vote = Vote.(v = var Pepperoni) in
        if_ pepperoni_vote
          ~then_:(pepperoni_total + constant Field.one)
          ~else_:pepperoni_total
      in
      go new_total vs'
  in
  go (constant Field.zero) vs
;;
(* Aside for experts: This function could be much more efficient since a Candidate
   is just a bool which can be coerced to a cvar (thus requiring literally no constraints
   to just sum up). It's written this way for pedagogical purposes. *)

(* Now we can put it all together to compute the winner: *)
let winner ballots =
  let open Number in
  let total_votes = List.length ballots in
  let half = constant (Field.of_int (total_votes / 2)) in
  (* First we open all the ballots *)
  let%bind votes = Checked.all (List.mapi ~f:open_ballot ballots) in
  (* Then we sum up all the votes (we only have to sum up the pepperoni votes
     since the mushroom votes are N - pepperoni votes)
  *)
  let%bind pepperoni_vote_count = count_pepperoni_votes votes in
  let%bind pepperoni_wins = pepperoni_vote_count > half in
  Vote.(if_ pepperoni_wins ~then_:(var Pepperoni) ~else_:(var Mushroom))
;;

let number_of_voters = 11

let check_winner commitments claimed_winner =
  let%bind w = winner commitments in
  Vote.assert_equal w claimed_winner

(* This specifies the data that will be exposed in the statement we're proving:
   a list of closed ballots (commitments to votes) and the winner. *)
let exposed () =
  let open Data_spec in
  [ Typ.list ~length:number_of_voters Ballot.Closed.typ
  ; Vote.typ
  ]

let keypair = generate_keypair check_winner ~exposing:(exposed ())

let winner (ballots : Ballot.Opened.t array) =
  let pepperoni_votes =
    Array.count ballots ~f:(function
      | (_, Pepperoni) -> true | (_, Mushroom) -> false)
  in
  if pepperoni_votes > Array.length ballots / 2
  then Vote.Pepperoni
  else Mushroom

let tally_and_prove (ballots : Ballot.Opened.t array) =
  let commitments =
    List.init number_of_voters ~f:(fun i ->
      Hash.hash (Ballot.Opened.to_bits ballots.(i)))
  in
  let winner = winner ballots in
  let handled_check commitments claimed_winner =
    (* As mentioned before, a checked computation can request help from outside.
       Here is where we answer those requests (or at least some of them). *)
    handle
      (check_winner commitments claimed_winner)
      (fun (With {request; respond}) ->
        match request with
        | Open_ballot i -> respond ballots.(i)
        | _ -> unhandled)
  in
  ( commitments
  , winner
  , prove (Keypair.pk keypair) (exposed ()) () handled_check
      commitments winner
  )

(* Now let's try it out: *)
let () =
  (* Mock data *)
  let received_ballots =
    Array.init number_of_voters ~f:(fun _ ->
      (Ballot.Opened.create
        (if Random.bool () then Pepperoni else Mushroom)))
  in
  let (commitments, winner, proof) = tally_and_prove received_ballots in
  assert
    (verify proof (Keypair.vk keypair) (exposed ())
       commitments winner)
