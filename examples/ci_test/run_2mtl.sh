#!/bin/bash

# Copyright 2020 Kyoto University (Hirofumi Inaguma)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

echo ============================================================================
echo "                                  CI Test                                 "
echo ============================================================================

stage=0
stop_stage=5
gpu=
benchmark=true
speed_perturb=false
stdout=false

### vocabulary
unit=char      # word/wp/char/word_char
vocab=50
wp_type=bpe  # bpe/unigram (for wordpiece)
unit_sub1=phone
wp_type_sub1=bpe  # bpe/unigram (for wordpiece)
vocab_sub1=

#########################
# ASR configuration
#########################
conf=conf/asr/blstm_las_2mtl.yaml
conf2=
asr_init=
external_lm=

### path to save the model
model=results

### path to the model directory to resume training
resume=
lm_resume=

. ./cmd.sh
. ./path.sh
. utils/parse_options.sh

set -e
set -u
set -o pipefail

if [ -z ${gpu} ]; then
    n_gpus=0
else
    n_gpus=$(echo ${gpu} | tr "," "\n" | wc -l)
fi

train_set=train
dev_set=train
if [ ${speed_perturb} = true ]; then
    train_set=train_sp
    dev_set=train_sp
fi

# main
if [ ${unit} = char ]; then
    vocab=
fi
if [ ${unit} != wp ]; then
    wp_type=
fi
# sub1
if [ ${unit_sub1} = char ]; then
    vocab_sub1=
fi
if [ ${unit_sub1} != wp ]; then
    wp_type_sub1=
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ] && [ ! -e data/.done_stage_0 ]; then
    echo ============================================================================
    echo "                       Data Preparation (stage:0)                          "
    echo ============================================================================

    # download data
    mkdir -p data
    local/download_sample.sh || exit 1;

    touch data/.done_stage_0 && echo "Finish data preparation (stage: 0)."
fi

if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ] && [ ! -e data/.done_stage_1_sp${speed_perturb} ]; then
    echo ============================================================================
    echo "                    Feature extranction (stage:1)                          "
    echo ============================================================================

    if [ ! -e data/.done_stage_1_spfalse ]; then
        steps/make_fbank.sh --nj 1 --cmd "$train_cmd" --write_utt2num_frames true \
            data/train data/log/make_fbank/train data/fbank || exit 1;
    fi

    if [ ${speed_perturb} = true ]; then
        speed_perturb_3way.sh --nj 1 data train ${train_set}
    fi

    compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark || exit 1;

    # Apply global CMVN & dump features
    dump_feat.sh --cmd "$train_cmd" --nj 1 \
        data/${train_set}/feats.scp data/${train_set}/cmvn.ark data/log/dump_feat/${train_set} data/dump/${train_set} || exit 1;

    touch data/.done_stage_1_sp${speed_perturb} && echo "Finish feature extranction (stage: 1)."
fi

# main
dict=data/dict/${train_set}_${unit}${wp_type}${vocab}.txt; mkdir -p data/dict
wp_model=data/dict/${train_set}_${wp_type}${vocab}
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ] && [ ! -e data/.done_stage_2_${unit}${wp_type}${vocab}_sp${speed_perturb} ]; then
    echo ============================================================================
    echo "                      Dataset preparation (stage:2, main)                  "
    echo ============================================================================

    if [ ${unit} = wp ]; then
        make_vocab.sh --unit ${unit} --speed_perturb ${speed_perturb} \
            --vocab ${vocab} --wp_type ${wp_type} --wp_model ${wp_model} \
            data ${dict} data/${train_set}/text || exit 1;
    else
        make_vocab.sh --unit ${unit} --speed_perturb ${speed_perturb} \
            data ${dict} data/${train_set}/text || exit 1;
    fi

    # Compute OOV rate
    if [ ${unit} = word ]; then
        mkdir -p data/dict/word_count data/dict/oov_rate
        echo "OOV rate:" > data/dict/oov_rate/word${vocab}.txt
        for x in ${train_set}; do
            cut -f 2- -d " " data/${x}/text | tr " " "\n" | sort | uniq -c | sort -n -k1 -r \
                > data/dict/word_count/${x}.txt || exit 1;
            compute_oov_rate.py data/dict/word_count/${x}.txt ${dict} ${x} \
                >> data/dict/oov_rate/word${vocab}.txt || exit 1;
            # NOTE: speed perturbation is not considered
        done
        cat data/dict/oov_rate/word${vocab}.txt
    fi

    echo "Making dataset tsv files for ASR ..."
    mkdir -p data/dataset
    make_dataset.sh --feat data/dump/${train_set}/feats.scp --unit ${unit} --wp_model ${wp_model} \
        data/${train_set} ${dict} > data/dataset/${train_set}_${unit}${wp_type}${vocab}.tsv || exit 1;

    touch data/.done_stage_2_${unit}${wp_type}${vocab}_sp${speed_perturb} && echo "Finish creating dataset for ASR (stage: 2)."
fi

# sub1
dict_sub1=data/dict/${train_set}_${unit_sub1}${wp_type_sub1}${vocab_sub1}.txt
wp_model_sub1=data/dict/${train_set}_${wp_type_sub1}${vocab_sub1}
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ] && [ ! -e data/.done_stage_2_${unit_sub1}${wp_type_sub1}${vocab_sub1}_sp${speed_perturb} ]; then
    echo ============================================================================
    echo "                      Dataset preparation (stage:2, sub1)                  "
    echo ============================================================================

    if [ ${unit_sub1} = wp ]; then
        make_vocab.sh --unit ${unit_sub1} --speed_perturb ${speed_perturb} \
            --vocab ${vocab_sub1} --wp_type ${wp_type_sub1} --wp_model ${wp_model_sub1} \
            data ${dict_sub1} data/${train_set}/text || exit 1;
    else
        make_vocab.sh --unit ${unit_sub1} --speed_perturb ${speed_perturb} \
            data ${dict_sub1} data/${train_set}/text || exit 1;
    fi

    echo "Making dataset tsv files for ASR ..."
    make_dataset.sh --feat data/dump/${train_set}/feats.scp --unit ${unit_sub1} --wp_model ${wp_model_sub1} \
        data/${train_set} ${dict_sub1} > data/dataset/${train_set}_${unit_sub1}${wp_type_sub1}${vocab_sub1}.tsv || exit 1;

    touch data/.done_stage_2_${unit_sub1}${wp_type_sub1}${vocab_sub1}_sp${speed_perturb} && echo "Finish creating dataset for ASR (stage: 2)."
fi

mkdir -p ${model}
if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
    echo ============================================================================
    echo "                       ASR Training stage (stage:4)                        "
    echo ============================================================================

    echo ${conf}
    echo ${conf2}
    CUDA_VISIBLE_DEVICES=${gpu} ${NEURALSP_ROOT}/neural_sp/bin/asr/train.py \
        --corpus ci_test \
        --config ${conf} \
        --config2 ${conf2} \
        --n_gpus ${n_gpus} \
        --cudnn_benchmark ${benchmark} \
        --train_set data/dataset/${train_set}_${unit}${wp_type}${vocab}.tsv \
        --train_set_sub1 data/dataset/${train_set}_${unit_sub1}${wp_type_sub1}${vocab_sub1}.tsv \
        --dev_set data/dataset/${dev_set}_${unit}${wp_type}${vocab}.tsv \
        --dev_set_sub1 data/dataset/${dev_set}_${unit_sub1}${wp_type_sub1}${vocab_sub1}.tsv \
        --eval_sets data/dataset/${dev_set}_${unit}${wp_type}${vocab}.tsv \
        --unit ${unit} \
        --unit_sub1 ${unit_sub1} \
        --dict ${dict} \
        --dict_sub1 ${dict_sub1} \
        --wp_model ${wp_model}.model \
        --wp_model_sub1 ${wp_model_sub1}.model \
        --model_save_dir ${model}/asr \
        --asr_init ${asr_init} \
        --external_lm ${external_lm} \
        --stdout ${stdout} \
        --resume ${resume} || exit 1;

    echo "Finish ASR model training (stage: 4)."
fi
