:- module(database,[
              query_context_transaction_objects/2,
              run_transaction/2,
              run_transactions/2,
              retry_transaction/2,
              with_transaction/3,
              graph_inserts_deletes/3
          ]).

/** <module> Implementation of database graph management
 *
 * This module helps other modules with the representation of databases and
 * their associated graphs by bundling them as objects with some convenience
 * operators and accessors.
 *
 * * * * * * * * * * * * * COPYRIGHT NOTICE  * * * * * * * * * * * * * * *
 *                                                                       *
 *  This file is part of TerminusDB.                                     *
 *                                                                       *
 *  TerminusDB is free software: you can redistribute it and/or modify   *
 *  it under the terms of the GNU General Public License as published by *
 *  the Free Software Foundation, under version 3 of the License.        *
 *                                                                       *
 *                                                                       *
 *  TerminusDB is distributed in the hope that it will be useful,        *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of       *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        *
 *  GNU General Public License for more details.                         *
 *                                                                       *
 *  You should have received a copy of the GNU General Public License    *
 *  along with TerminusDB.  If not, see <https://www.gnu.org/licenses/>. *
 *                                                                       *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

:- use_module(core(transaction/descriptor)).
:- use_module(core(transaction/validate)).
:- use_module(core(util)).
:- use_module(core(util/utils)).
:- use_module(core(triple), [xrdf_added/4, xrdf_deleted/4]).

:- use_module(library(prolog_stack)).
:- use_module(library(apply)).
:- use_module(library(apply_macros)).
:- use_module(library(terminus_store)).


descriptor_database_name(Descriptor, 'system:///terminus') :-
    system_descriptor{} = Descriptor,
    !.
descriptor_database_name(Descriptor, ID) :-
    id_descriptor{ id : ID } = Descriptor.
descriptor_database_name(Descriptor, Label) :-
    label_descriptor{ label : Label } = Descriptor.
descriptor_database_name(Descriptor, Name) :-
    database_descriptor{ database_name : Name } = Descriptor,
    !.
descriptor_database_name(Descriptor, Name) :-
    repository_descriptor{ repository_name : _,
                           database_descriptor : DB_Descriptor} = Descriptor,
    !,
    descriptor_database_name(DB_Descriptor, Name).
descriptor_database_name(Descriptor, Name) :-
    branch_descriptor{ branch_name : _,
                       repository_descriptor : Repo_Descriptor } = Descriptor,
    !,
    descriptor_database_name(Repo_Descriptor, Name).

transaction_database_name(Transaction, Name) :-
    descriptor_database_name(Transaction.descriptor, Name).

same_hierarchy(Transaction1, Transaction2) :-
    transaction_database_name(Transaction1,Name),
    transaction_database_name(Transaction2,Name).

partition_by_root(Transaction_Objects, Partitions) :-
    partition_by_root_(Transaction_Objects, [], Partitions).

partition_by_root_([], Partitions, Partitions).
partition_by_root_([Transaction|Tail], Partitions_So_Far, Final) :-
    select(Partition, Partitions_So_Far, [Transaction|Partition], Partitions),
    Partition = [Partition_Transaction|_],
    \+ memberchk(Transaction, Partition),
    same_hierarchy(Transaction, Partition_Transaction),
    !,
    partition_by_root_(Tail,Partitions,Final).
partition_by_root_([Transaction|Tail], Partitions_So_Far, Final) :-
    % A new partition
    partition_by_root_(Tail, [[Transaction]|Partitions_So_Far], Final).

/**
 * multi_transaction(Query_Context) is semidet.
 *
 * Is true if we more than one database - this makes rollback consistency impossible.
 */
multi_transaction(Query_Context) :-
    Transaction_Objects = Query_Context.transaction_objects,
    partition_by_root(Transaction_Objects, Partitions),
    length(Partitions, N),
    N \= 1.


read_write_obj_already_committed(RW_Obj) :-
    RW_Obj = read_write_obj{ descriptor: _Descriptor,
                             read: _Layer,
                             write: Layer_Builder },
    nonvar(Layer_Builder),
    builder_committed(Layer_Builder).

already_committed(Transaction_Object) :-
    Instance_Objects = Transaction_Object.instance_objects,
    exists(read_write_obj_already_committed,Instance_Objects).
already_committed(Transaction_Object) :-
    Schema_Objects = Transaction_Object.schema_objects,
    exists(read_write_obj_already_committed,Schema_Objects).
already_committed(Transaction_Object) :-
    Inference_Objects = Transaction_Object.inference_objects,
    exists(read_write_obj_already_committed,Inference_Objects).

/*
 * partial_commits(Query_Context) is semidet
 *
 * Is true if we are a partial commit. i.e. bad.
 */
partial_commits(Query_Context) :-
    exists(already_committed, Query_Context.transaction_objects).

slot_size(4).
slot_coefficient(0.25).
slot_time(0.1).

/*
 * compute_backoff(Count, Time) is det.
 *
 * Computes the number of seconds to back off from a transaction
 */
compute_backoff(Count, Time) :-
    slot_size(Slot),
    slot_coefficient(C),
    Slots is floor(C * (Slot ** Count)) + 1,
    random(0,Slots,This_Slot),
    slot_time(Slot_Time),
    Time is This_Slot * Slot_Time.

reset_read_write_obj(Read_Write_Obj) :-
    nb_set_dict(read, Read_Write_Obj, _),
    nb_set_dict(write, Read_Write_Obj, _).

reset_transaction_object_graph_descriptors(Transaction_Object) :-
    transaction_object{
        instance_objects : Instance_Objects,
        schema_objects : Schema_Objects,
        inference_objects : Inference_Objects
    } :< Transaction_Object,
    maplist(reset_read_write_obj, Instance_Objects),
    maplist(reset_read_write_obj, Schema_Objects),
    maplist(reset_read_write_obj, Inference_Objects).

/**
 *
 */
reset_transaction_objects_graph_descriptors(Transaction_Objects) :-
    maplist(reset_transaction_object_graph_descriptors, Transaction_Objects).

/**
 * reset_query_context(Query_Context) is semidet.
 *
 * Attempts to re-open a query context.
 */
reset_query_context(Query_Context) :-
    reset_transaction_objects_graph_descriptors(
        Query_Context.transaction_objects
    ).

/**
 * retry_transaction(Query_Context, Recount_Number) is nondet.
 *
 * Retry transaction sets up some number of choice points for
 * retrying a transaction together with a back-off strategy.
 *
 * If it is impossible to back out of a transaction (partial commits
 * in the case of multi-database transactions), we instead through an error and
 * complain.
 *
 * WARNING: This is a side-effecting operation
 */
retry_transaction(Query_Context, Transaction_Retry_Count) :-
    config:max_transaction_retries(Max_Transaction_Retries),

    between(0, Max_Transaction_Retries, Transaction_Retry_Count),

    % If we are > 0, we have actually failed at least once.
    (   Transaction_Retry_Count > 0
    ->  (   multi_transaction(Query_Context),
            partial_commits(Query_Context)
        ->  throw(error(multi_transaction_error("We are in a multi transaction which has partially commited"),context(retry_transaction/1,Query_Context)))
        ;   true),
        % This is side-effecting!!!
        reset_query_context(Query_Context),
        compute_backoff(Transaction_Retry_Count,BackOff),
        sleep(BackOff)
    ;   true).

/**
 * with_transaction(+Query_Context, +Body, -Meta_Data) is semidet.
 *
 * Performs a transaction after Body is run.
 *
 * The body is assumed semidet.
 */
:- meta_predicate with_transaction(?,0,?).
with_transaction(Query_Context,
                 Body,
                 Meta_Data) :-
    retry_transaction(Query_Context, Transaction_Retry_Count),
    (   call(Body)
    ->  query_context_transaction_objects(Query_Context, Transactions),
        run_transactions(Transactions,Meta_Data0),
        !, % No going back now!
        Meta_Data = Meta_Data0.put(_{transaction_retry_count : Transaction_Retry_Count})
    ;   !,
        fail).

/*
 * run_transaction(Transaction) is det.
 *
 * Run transaction and throw errors with witnesses.
 *
 */
run_transaction(Transaction, Meta_Data) :-
    run_transactions([Transaction], Meta_Data).

/*
 * run_transactions(Transaction, Meta_Data) is det.
 *
 * Run all transactions and throw errors with witnesses.
 */
run_transactions(Transactions, Meta_Data) :-
    transaction_objects_to_validation_objects(Transactions, Validations),
    validate_validation_objects(Validations,Witnesses),
    (   Witnesses = []
    ->  true
    ;   throw(error(schema_check_failure(Witnesses)))),
    commit_validation_objects(Validations),
    collect_validations_metadata(Validations, Meta_Data).

graph_inserts_deletes(Graph, I, D) :-
    graph_validation_obj{ changed: Value } :< Graph,
    (   ground(Value),
        Value = true
    ;   var(Value)),
    !,
    % layer_addition_count(Graph.read, I),
    %layer_removal_count(Graph.read, D).
    findall(1,
            xrdf_deleted([Graph], _, _, _),
            Delete_List),
    sumlist(Delete_List, D),
    findall(1,
            xrdf_added([Graph], _, _, _),
            Insert_List),
    sumlist(Insert_List, I).
graph_inserts_deletes(_Graph, 0, 0).

validation_inserts_deletes(Validation, Inserts, Deletes) :-
    % only count if we are in a branch or terminus commit
    validation_object{
        descriptor : Descriptor,
        instance_objects : Instance_Objects,
        schema_objects : Schema_Objects,
        inference_objects : Inference_Objects
    } :< Validation,
    (   Descriptor = branch_descriptor{ branch_name : _,
                                        repository_descriptor : _}
    ->  true
    ;   Descriptor = system_descriptor{}),
    !,
    foldl([Graph,(I0,D0),(I1,D1)]>>(
              graph_inserts_deletes(Graph, I, D),
              I1 is I0 + I,
              D1 is D0 + D
          ),
          Instance_Objects, (0,0), (Insert_0, Delete_0)),
    foldl([Graph,(I0,D0),(I1,D1)]>>(
              graph_inserts_deletes(Graph, I, D),
              I1 is I0 + I,
              D1 is D0 + D
          ),
          Inference_Objects, (Insert_0,Delete_0), (Insert_1, Delete_1)),
    foldl([Graph,(I0,D0),(I1,D1)]>>(
              graph_inserts_deletes(Graph, I, D),
              I1 is I0 + I,
              D1 is D0 + D
          ),
          Schema_Objects, (Insert_1,Delete_1), (Inserts, Deletes)).
validation_inserts_deletes(_Validation, 0, 0).

/*
 * collect_validations_metadata(Validations, Meta_Data) is det.
 */
collect_validations_metadata(Validations, Meta_Data) :-
    foldl([Validation,R0,R1]>>(
              validation_inserts_deletes(Validation, Inserts, Deletes),
              get_dict(inserts,R0,Current_Inserts),
              New_Inserts is Current_Inserts + Inserts,
              get_dict(deletes,R0,Current_Deletes),
              New_Deletes is Current_Deletes + Deletes,
              put_dict(meta_data{inserts : New_Inserts,
                                 deletes : New_Deletes
                                }, R0, R1)
          ),
          Validations,
          meta_data{
              inserts : 0,
              deletes : 0
          },
          Meta_Data).


/*
 * query_context_transaction_objects(+Query_Object,Transaction_Objects) is det.
 *
 * Marshall commit info into the transaction object and run it.
 */
query_context_transaction_objects(Query_Context,Transaction_Objects) :-
    maplist({Query_Context}/[Transaction_Object,New_Transaction_Object]>>(
                (   branch_descriptor{} :< Transaction_Object.descriptor
                ->  get_dict(commit_info,Query_Context,Commit_Info),
                    put_dict(_{commit_info : Commit_Info},
                             Transaction_Object,
                             New_Transaction_Object)
                ;   New_Transaction_Object = Transaction_Object)
            ),
            Query_Context.transaction_objects,
            Transaction_Objects).

:- begin_tests(database_transactions).
:- use_module(core(util/test_utils)).
:- use_module(core(triple)).
:- use_module(core(api)).
:- use_module(core(query)).
:- use_module(library(terminus_store)).

test(test_transaction_partition, [
         setup((setup_temp_store(State),
                user_database_name(admin,testdb1,Name1),
                create_db_without_schema(Name1, 'test','a test'),
                user_database_name(admin,testdb2,Name2),
                create_db_without_schema(Name2, 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ])
:-

    make_branch_descriptor(admin,testdb1,Desc1),
    make_branch_descriptor(admin,testdb2,Desc2),
    open_descriptor(Desc1, Trans1),
    open_descriptor(Desc2, Trans2),
    Transactions = [Trans1,Trans2],
    multi_transaction(query_context{transaction_objects : Transactions}).


test(partial_transaction_commit, [
         setup((setup_temp_store(State),
                user_database_name(admin,testdb1,Name1),
                create_db_without_schema(Name1, 'test','a test'),
                user_database_name(admin,testdb2,Name2),
                create_db_without_schema(Name2, 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ])
:-

    make_branch_descriptor(admin,testdb1,Desc1),
    make_branch_descriptor(admin,testdb2,Desc2),
    create_context(Desc1, Context1),

    open_descriptor(Desc2, Pre_Transaction2),

    Transaction2 = Pre_Transaction2.put(_{commit_info : commit_info{ author : test,
                                                                     message : test}
                                         }),


    Transaction1_List = Context1.transaction_objects,

    Transactions = [Transaction2|Transaction1_List],

    Context = Context1.put(_{ transaction_objects : Transactions,
                              commit_info : commit_info{ author : test,
                                                         message : test}
                            }),

    ask(Context,
        insert(doc:a, doc:b, doc:c)),

    query_context_transaction_objects(Context,Transaction_Objects),
    run_transactions(Transaction_Objects, _),

    partial_commits(Context).

:- end_tests(database_transactions).
