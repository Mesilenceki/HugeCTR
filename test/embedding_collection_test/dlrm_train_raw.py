import hugectr
from mpi4py import MPI


def generate_plan(slot_size_array, num_gpus):
    mp_table = [i for i in range(len(slot_size_array)) if slot_size_array[i] > 6000]
    dp_table = [i for i in range(len(slot_size_array)) if slot_size_array[i] <= 6000]
    shard_matrix = [[0 for _ in range(len(slot_size_array))] for _ in range(num_gpus)]
    emb_table_group_strategy = [[], []]
    emb_table_placement_strategy = ["mp", "dp"]

    for table_id in dp_table:
        for gpu_id in range(num_gpus):
            shard_matrix[gpu_id][table_id] = 1
        emb_table_group_strategy[emb_table_placement_strategy.index("dp")].append(table_id)

    for i, table_id in enumerate(mp_table):
        target_gpu = i % num_gpus
        shard_matrix[target_gpu][table_id] = 1
        emb_table_group_strategy[emb_table_placement_strategy.index("mp")].append(table_id)
    return shard_matrix, emb_table_group_strategy, emb_table_placement_strategy


solver = hugectr.CreateSolver(
    max_eval_batches=70,
    batchsize_eval=8,  # 65536,
    batchsize=8,  # 65536,
    lr=0.5,
    warmup_steps=300,
    vvgpu=[[0, 1, 2, 3, 4, 5, 6, 7]],
    repeat_dataset=True,
    i64_input_key=False,
    metrics_spec={hugectr.MetricsType.AverageLoss: 0.0},
    use_embedding_collection=True,
)
"""
slot_size_array=[
        39884406,
        39043,
        17289,
        7420,
        20263,
        3,
        7120,
        1543,
        63,
        38532951,
        2953546,
        403346,
        10,
        2208,
        11938,
        155,
        4,
        976,
        14,
        39979771,
        25641295,
        39664984,
        585935,
        12972,
        108,
        36,
    ]
"""
slot_size_array = [
    203931,
    18598,
    14092,
    7012,
    18977,
    4,
    6385,
    1245,
    49,
    186213,
    71328,
    67288,
    11,
    2168,
    7338,
    61,
    4,
    932,
    15,
    204515,
    141526,
    199433,
    60919,
    9137,
    71,
    34,
]

batchsize = 65536
num_reading_threads = 1
num_batches_per_threads = 2
expected_io_block_size = batchsize * 10
io_depth = 2
io_alignment = 512
bytes_size_per_batches = (26 + 1 + 13) * 4 * batchsize
max_nr_per_threads = num_batches_per_threads * (
    bytes_size_per_batches // expected_io_block_size + 2
)


reader = hugectr.DataReaderParams(
    data_reader_type=hugectr.DataReaderType_t.RawAsync,
    source=["/raid/datasets/criteo/mlperf/40m.limit_preshuffled/train_data.bin"],
    eval_source="/raid/datasets/criteo/mlperf/40m.limit_preshuffled/test_data.bin",
    check_type=hugectr.Check_t.Non,
    num_samples=4195197692,
    eval_num_samples=89137319,
    cache_eval_data=51,
    slot_size_array=slot_size_array,
    # max_nr_per_threads  = num_batches_per_threads  * (bytes_size_per_batches / io_block_size + 2)
    # max_nr_per_threads  = 4 * (55296 * 160 / 552960 + 2  ) = 4 * 18 = 72
    async_param=hugectr.AsyncParam(
        num_reading_threads,
        num_batches_per_threads,
        max_nr_per_threads,
        io_depth,
        io_alignment,
        False,
        hugectr.Alignment_t.Auto,
    ),
)

"""
reader = hugectr.DataReaderParams(
    data_reader_type=hugectr.DataReaderType_t.Raw,
    source=["/raid/datasets/criteo/mlperf/40m.limit_preshuffled/train_data.bin"],
    eval_source="/raid/datasets/criteo/mlperf/40m.limit_preshuffled/test_data.bin",
    check_type=hugectr.Check_t.Non,
    num_samples=4195197692,
    eval_num_samples=89137319,
    cache_eval_data=51,
)"""


# reader = hugectr.DataReaderParams(
#    data_reader_type=hugectr.DataReaderType_t.Parquet,
#    source=["./criteo_data/train/_file_list.txt"],
#    eval_source="./criteo_data/train/_file_list.txt",
#    check_type=hugectr.Check_t.Non,
#    slot_size_array=slot_size_array,
# )
optimizer = hugectr.CreateOptimizer(
    optimizer_type=hugectr.Optimizer_t.SGD, update_type=hugectr.Update_t.Local, atomic_update=True
)
model = hugectr.Model(solver, reader, optimizer)

num_embedding = 26

model.add(
    hugectr.Input(
        label_dim=1,
        label_name="label",
        dense_dim=13,
        dense_name="dense",
        data_reader_sparse_param_array=[
            hugectr.DataReaderSparseParam("data{}".format(i), 1, False, 1)
            for i in range(num_embedding)
        ],
    )
)

# create embedding table
embedding_table_list = []
for i in range(num_embedding):
    embedding_table_list.append(
        hugectr.EmbeddingTableConfig(
            table_id=i, max_vocabulary_size=slot_size_array[i], ev_size=128
        )
    )
# create embedding planner and embedding collection
embedding_planner = hugectr.EmbeddingPlanner()
emb_vec_list = []
for i in range(num_embedding):
    embedding_planner.embedding_lookup(
        table_config=embedding_table_list[i],
        bottom_name="data{}".format(i),
        top_name="emb_vec{}".format(i),
        combiner="sum",
    )
shard_matrix, emb_table_group_strategy, emb_table_placement_strategy = generate_plan(
    slot_size_array, 8
)
embedding_collection = embedding_planner.create_embedding_collection(
    shard_matrix=shard_matrix,
    emb_table_group_strategy=emb_table_group_strategy,
    emb_table_placement_strategy=emb_table_placement_strategy,
)

model.add(embedding_collection)
# need concat
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.Concat,
        bottom_names=["emb_vec{}".format(i) for i in range(num_embedding)],
        top_names=["sparse_embedding1"],
    )
)

model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.InnerProduct,
        bottom_names=["dense"],
        top_names=["fc1"],
        num_output=512,
    )
)
model.add(
    hugectr.DenseLayer(layer_type=hugectr.Layer_t.ReLU, bottom_names=["fc1"], top_names=["relu1"])
)
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.InnerProduct,
        bottom_names=["relu1"],
        top_names=["fc2"],
        num_output=256,
    )
)
model.add(
    hugectr.DenseLayer(layer_type=hugectr.Layer_t.ReLU, bottom_names=["fc2"], top_names=["relu2"])
)
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.InnerProduct,
        bottom_names=["relu2"],
        top_names=["fc3"],
        num_output=128,
    )
)
model.add(
    hugectr.DenseLayer(layer_type=hugectr.Layer_t.ReLU, bottom_names=["fc3"], top_names=["relu3"])
)
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.Interaction,  # interaction only support 3-D input
        bottom_names=["relu3", "sparse_embedding1"],
        top_names=["interaction1"],
    )
)
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.InnerProduct,
        bottom_names=["interaction1"],
        top_names=["fc4"],
        num_output=1024,
    )
)
model.add(
    hugectr.DenseLayer(layer_type=hugectr.Layer_t.ReLU, bottom_names=["fc4"], top_names=["relu4"])
)
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.InnerProduct,
        bottom_names=["relu4"],
        top_names=["fc5"],
        num_output=1024,
    )
)
model.add(
    hugectr.DenseLayer(layer_type=hugectr.Layer_t.ReLU, bottom_names=["fc5"], top_names=["relu5"])
)
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.InnerProduct,
        bottom_names=["relu5"],
        top_names=["fc6"],
        num_output=512,
    )
)
model.add(
    hugectr.DenseLayer(layer_type=hugectr.Layer_t.ReLU, bottom_names=["fc6"], top_names=["relu6"])
)
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.InnerProduct,
        bottom_names=["relu6"],
        top_names=["fc7"],
        num_output=256,
    )
)
model.add(
    hugectr.DenseLayer(layer_type=hugectr.Layer_t.ReLU, bottom_names=["fc7"], top_names=["relu7"])
)
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.InnerProduct,
        bottom_names=["relu7"],
        top_names=["fc8"],
        num_output=1,
    )
)
model.add(
    hugectr.DenseLayer(
        layer_type=hugectr.Layer_t.BinaryCrossEntropyLoss,
        bottom_names=["fc8", "label"],
        top_names=["loss"],
    )
)
model.compile()
model.summary()
model.fit(max_iter=1000, display=100, eval_interval=100, snapshot=10000000, snapshot_prefix="dlrm")
