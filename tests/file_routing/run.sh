#!/bin/sh
#
# Copyright 2019 PingCAP, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# See the License for the specific language governing permissions and
# limitations under the License.

set -euE

# Populate the mydumper source
DBPATH="$TEST_DIR/fr.mydump"

mkdir -p $DBPATH $DBPATH/fr $DBPATH/ff
echo 'CREATE DATABASE fr;' > "$DBPATH/fr/schema.sql"
echo "CREATE TABLE tbl(i TINYINT PRIMARY KEY, j INT);" > "$DBPATH/fr/tbl-table.sql"
# the column orders in data file is different from table schema order.
echo "INSERT INTO tbl (i, j) VALUES (1, 1),(2, 2);" > "$DBPATH/fr/tbl1.sql.0"
echo "INSERT INTO tbl (i, j) VALUES (3, 3),(4, 4);" > "$DBPATH/fr/tbl2.sql.0"
echo "INSERT INTO tbl (i, j) VALUES (5, 5);" > "$DBPATH/fr/tbl.sql"
echo "INSERT INTO tbl (i, j) VALUES (6, 6), (7, 7), (8, 8), (9, 9);" > "$DBPATH/tbl1.sql.1"
echo "INSERT INTO tbl (i, j) VALUES (10, 10);" > "$DBPATH/ff/test.SQL"
echo "INSERT INTO tbl (i, j) VALUES (11, 11);" > "$DBPATH/fr/tbl-noused.sql"

# Set minDeliverBytes to a small enough number to only write only 1 row each time
# Set the failpoint to kill the lightning instance as soon as one row is written

# Start importing the tables.
run_sql 'DROP DATABASE IF EXISTS fr'

set +e
run_lightning -d "$DBPATH" --backend local 2> /dev/null
set -e
run_sql 'SELECT count(*) FROM `fr`.tbl'
check_contains "count(*): 10"

run_sql 'SELECT sum(j) FROM `fr`.tbl'
check_contains "sum(j): 55"
