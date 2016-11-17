#! /usr/bin/python3
from subprocess import call
import sys
import numpy as np
import pandas as pd

def test_case(df):
    df['nsecperiter']=(df['duration']*1000)/(df['nbiter'])
    stdev = pd.DataFrame({'perevent_stdev' : 
                          df.groupby(['nbthreads', 'tracer', 'testcase','sleeptime'])['nsecperiter'].std()}).reset_index()
    mean = pd.DataFrame({'perevent_mean' :
                         df.groupby(['nbthreads', 'tracer', 'testcase','sleeptime'])['nsecperiter'].mean()}).reset_index()
    mem_mean = pd.DataFrame({'mem_mean' :
                             df.groupby(['nbthreads','tracer','testcase','sleeptime'])['maxmem'].mean()}).reset_index()
    mem_stdev = pd.DataFrame({'mem_stdev' :
                              df.groupby(['nbthreads','tracer','testcase','sleeptime'])['maxmem'].std()}).reset_index()
    tmp = mean.merge(stdev)
    tmp = tmp.merge(mem_mean)
    tmp = tmp.merge(mem_stdev)


    for i, row in tmp.iterrows():
        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'pereventmean'])
        yield( {"name": testcase_name, "result": "pass", "units": "nsec/event",
            "measurement": str(row['perevent_mean'])})

        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'pereventstdev'])
        yield( {"name": testcase_name, "result": "pass", "units": "nsec/event",
            "measurement": str(row['perevent_stdev'])})

        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'memmean'])
        yield( {"name": testcase_name, "result": "pass", "units": "kB",
            "measurement": str(row['mem_mean'])})

        testcase_name='_'.join([row['tracer'],str(row['nbthreads'])+'thr', 'memstdev'])
        yield( {"name": testcase_name, "result": "pass", "units": "kB",
            "measurement": str(row['mem_stdev'])})


def main():
    results_file=sys.argv[1]
    df = pd.read_csv(results_file)
    data = test_case(df)
    for res in data:
        call(
            ['lava-test-case',
            res['name'],
            '--result', res['result'],
            '--measurement', res['measurement'],
            '--units', res['units']])

if __name__ == '__main__':
    main()
