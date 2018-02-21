#! /usr/bin/python3
from subprocess import call
from collections import defaultdict
import csv
import numpy as np
import pandas as pd
import sys

def test_case(df):
    # Duration is in usec
    # usecPecIter = Duration/(average number of iteration per thread)
    df['usecperiter'] = (df['nbthreads'] * df['duration']) / df['nbiter']

    periter_mean = pd.DataFrame({'periter_mean' :
                         df.groupby(['nbthreads', 'tracer', 'testcase','sleeptime'])['usecperiter'].mean()}).reset_index()

    periter_stdev = pd.DataFrame({'periter_stdev' :
                          df.groupby(['nbthreads', 'tracer', 'testcase','sleeptime'])['usecperiter'].std()}).reset_index()

    nbiter_mean = pd.DataFrame({'nbiter_mean' :
                          df.groupby(['nbthreads', 'tracer', 'testcase','sleeptime'])['nbiter'].mean()}).reset_index()

    nbiter_stdev = pd.DataFrame({'nbiter_stdev' :
                          df.groupby(['nbthreads', 'tracer', 'testcase','sleeptime'])['nbiter'].std()}).reset_index()

    duration_mean = pd.DataFrame({'duration_mean' :
                         df.groupby(['nbthreads', 'tracer', 'testcase','sleeptime'])['duration'].mean()}).reset_index()

    duration_stdev = pd.DataFrame({'duration_stdev' :
                         df.groupby(['nbthreads', 'tracer', 'testcase','sleeptime'])['duration'].std()}).reset_index()

    tmp = periter_mean.merge(periter_stdev)

    tmp = tmp.merge(nbiter_mean)
    tmp = tmp.merge(nbiter_stdev)

    tmp = tmp.merge(duration_mean)
    tmp = tmp.merge(duration_stdev)

    # if there is any NaN or None value in the DF we raise an exeception
    if tmp.isnull().values.any():
        raise Exception('NaN value found in dataframe')

    for i, row in tmp.iterrows():
        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'peritermean'])
        yield( {"name": testcase_name, "result": "pass", "units": "usec/iter",
            "measurement": str(row['periter_mean'])})

        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'periterstdev'])
        yield( {"name": testcase_name, "result": "pass", "units": "usec/iter",
            "measurement": str(row['periter_stdev'])})

        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'nbitermean'])
        yield( {"name": testcase_name, "result": "pass", "units": "iterations",
            "measurement": str(row['nbiter_mean'])})

        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'nbiterstdev'])
        yield( {"name": testcase_name, "result": "pass", "units": "iterations",
            "measurement": str(row['nbiter_stdev'])})

        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'durationmean'])
        yield( {"name": testcase_name, "result": "pass", "units": "usec",
            "measurement": str(row['duration_mean'])})

        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'durationstdev'])
        yield( {"name": testcase_name, "result": "pass", "units": "usec",
            "measurement": str(row['duration_stdev'])})

def main():
    results_file=sys.argv[1]
    df = pd.read_csv(results_file)
    results=defaultdict()
    data = test_case(df)
    for res in data:
        call(
            ['lava-test-case',
            res['name'],
            '--result', res['result'],
            '--measurement', res['measurement'],
            '--units', res['units']])

        # Save the results to write to the CSV file
        results[res['name']]=res['measurement']

    # Write the dictionnary to a csv file where each key is a column
    with open('processed_results.csv', 'w') as output_csv:
        dict_csv_write=csv.DictWriter(output_csv, results.keys())
        dict_csv_write.writeheader()
        dict_csv_write.writerow(results)

if __name__ == '__main__':
    main()
