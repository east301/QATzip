#***************************************************************************
#
#   BSD LICENSE
#
#   Copyright(c) 2007-2017 Intel Corporation. All rights reserved.
#   All rights reserved.
#
#   Redistribution and use in source and binary forms, with or without
#   modification, are permitted provided that the following conditions
#   are met:
#
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in
#       the documentation and/or other materials provided with the
#       distribution.
#     * Neither the name of Intel Corporation nor the names of its
#       contributors may be used to endorse or promote products derived
#       from this software without specific prior written permission.
#
#   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
#   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
#   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
#   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
#**************************************************************************

#! /bin/bash
set -e

readonly BASEDIR=$(cd `dirname $0`; pwd)
test_qzip="${BASEDIR}/../../utils/qzip "
test_main="${BASEDIR}/../test "
test_bt="${BASEDIR}/../bt "
test_file_path="/opt/compressdata"
huge_file_name="calgary.2G"

# 1. Trivial file compression
echo "Preforming file compression and decompression..."
test_file=test.tmp
test_str="THIS IS TEST STRING !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
format_option="qz:$((32*1024))/qz:$((64*1024))/qz:$((128*1024))/qz:$((64*1024))"
format_option+="/qz:$((32*1024))/qz:$((256*1024))"
echo "format_option=$format_option"


# 1.1 QAT Compression and Decompress
echo $test_str > $test_file
$test_qzip $test_file          #compress
$test_qzip ${test_file}.gz -d  #decompress

if [ "$test_str" == "$(cat $test_file)" ]; then
    echo "QAT file compression and decompression OK :)"
else
    echo "QAT file compression and decompression FAILED!!! :("
    exit 1
fi

# 1.2 SW Compression and Decompress
if [ -d  $ICP_ROOT/CRB_modules ];
then
  DRIVER_DIR=$ICP_ROOT/CRB_modules;
else
  DRIVER_DIR=$ICP_ROOT/build;
fi
$DRIVER_DIR/adf_ctl down

echo $test_str > $test_file
$test_qzip $test_file 1>/dev/null 2>/dev/null          #compress
$test_qzip ${test_file}.gz -d  1>/dev/null 2>/dev/null #decompress

if [ "$test_str" == "$(cat $test_file)" ]; then
    echo "SW file compression and decompression OK :)"
else
    echo "SW file compression and decompression FAILED!!! :("
    exit 1
fi

$DRIVER_DIR/adf_ctl up

# 1.3 check sw  compatibility with extra flag
head -c $((4*1024*1024)) /dev/urandom | od -x > $test_file
gzip $test_file
$test_qzip $test_file.gz -d
[[ $? -ne 0 ]] && { echo "QAT file compression FAILED !!!"; exit 1; }

#clear test file
rm -f ${test_file}.gz ${test_file}

function testOn3MBRandomDataFile()
{
    dd if=/dev/urandom of=random-3m.txt bs=3M count=1;
    $test_main -m 4 -t 3 -l 8 -i random-3m.txt;
    rc=`echo $?`;
    rm -f random-3m.txt;
    return $rc;
}

function hugeFileTest()
{
    if [ ! -f "$test_file_path/$huge_file_name" ]
    then
        echo "$test_file_path/$huge_file_name does not exit!"
        return 1
    fi

    cp -f $test_file_path/$huge_file_name ./
    orig_checksum=`md5sum $huge_file_name`
    if $test_qzip $huge_file_name && \
        $test_qzip -d "$huge_file_name.gz"
    then
        echo "(De)Compress $huge_file_name OK";
        rc=0
    else
        echo "(De)Compress $huge_file_name Failed";
        rc=1
    fi
    new_checksum=`md5sum $huge_file_name`

    if [[ $new_checksum != $orig_checksum ]]
    then
        echo "Checksum mismatch, huge file test failed."
        rc=1
    fi

    return $rc
}

#insufficent huge page memory, switch to sw
function switch_to_sw_failover_in_insufficent_HP()
{
    current_num_HP=`awk '/HugePages_Total/ {print $NF}' /proc/meminfo`
    echo 8 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

    for service in 'comp' 'decomp'
    do
       if $test_main -m 4 -D $service ; then
           echo "test qatzip $service with insufficent huge page memory PASSED"
       else
           echo "test qatzip $service with insufficent huge page memory FAILED"
           break
       fi
    done

    echo $current_num_HP > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    return $?
}

#get available huge page memory while some processes has already swithed to the sw
function resume_hw_comp_when_insufficent_HP()
{
    current_num_HP=`awk '/HugePages_Total/ {print $NF}' /proc/meminfo`
    dd if=/dev/urandom of=random-3m.txt bs=100M count=1;

    # 9 huge pages needed by each process in mode 4
    echo 12 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    echo -e "\n\nInsufficent huge page for 2 processes"
    cat /proc/meminfo | grep "HugePages_Total\|HugePages_Free"

    for proc in `seq 1 2`; do
        $test_qzip random-3m.txt -k &
    done

    sleep 1
    #show current huge page
    echo -e "\n\nCurrent free huge page"
    cat /proc/meminfo | grep "HugePages_Total\|HugePages_Free"

    #re-allocate huge page
    echo -e "\n\nResume huge age"
    echo $current_num_HP > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    cat /proc/meminfo | grep "HugePages_Total\|HugePages_Free"
    echo; echo

    for proc in `seq 1 2`; do
      $test_qzip random-3m.txt -k &
    done

    wait
    rm -f random-3m*
    return $?
}


# 2. Very basic misc functional tests
echo "Preforming misc functional tests..."
if $test_main -m 1 -t 3 -l 8 && \
    # ignore test2 output (too verbose) \
   $test_main -m 2 -t 3 -l 8 > /dev/null && \
   $test_main -m 3 -t 3 -l 8 && \
   $test_main -m 4 -t 3 -l 8 && \
   testOn3MBRandomDataFile && \
   hugeFileTest && \
   switch_to_sw_failover_in_insufficent_HP && \
   resume_hw_comp_when_insufficent_HP && \
   $test_main -m 5 -t 3 -l 8 -F $format_option && \
   $test_main -m 6 && \
   $test_main -m 7 -t 1 -l 8 && \
   $test_main -m 8 && \
   $test_main -m 9
then
    echo "Functional tests OK"
else
    echo "Functional tests FAILED!!! :(";
    exit 2
fi

# 3. Basic tests

echo "Preforming basic tests..."
if $test_bt -c 0 -S 200000 && \
   $test_bt -c 1 -f -S 200000 && \
   $test_bt -c 1 -S 200000 && \
   $test_bt -c 2 -S 200000
then
    echo "Basic tests OK"
else
    echo "Basic tests FAILED!!! :(";
    exit 2
fi

exit 0
