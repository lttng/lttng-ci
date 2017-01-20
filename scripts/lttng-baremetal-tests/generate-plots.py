# Copyright (C) 2017 - Francis Deslauriers <francis.deslauriers@efficios.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


import os, sys
import numpy as np
import pandas as pd

#Set Matplotlib to use the PNG non interactive backend
import matplotlib as mpl
mpl.use('Agg')

import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator
from cycler import cycler

def rename_cols(df):
    new_cols = {'baseline_1thr_peritermean': 'basel_1thr',
            'baseline_2thr_peritermean': 'basel_2thr',
            'baseline_4thr_peritermean': 'basel_4thr',
            'baseline_8thr_peritermean': 'basel_8thr',
            'baseline_16thr_peritermean': 'basel_16thr',
            'lttng_1thr_peritermean': 'lttng_1thr',
            'lttng_2thr_peritermean': 'lttng_2thr',
            'lttng_4thr_peritermean': 'lttng_4thr',
            'lttng_8thr_peritermean': 'lttng_8thr',
            'lttng_16thr_peritermean': 'lttng_16thr'
            }
    df.rename(columns=new_cols, inplace=True)
    return df

def convert_us_to_ns(df):
    cols = [col for col in df.columns if 'periter' in col]
    df[cols] = df[cols].apply(lambda x: x*1000)
    return df

def create_plot(df, graph_type):
    # We split the data into two plots so it's easier to read
    lower = ['basel_1thr', 'basel_2thr', 'basel_4thr', 'lttng_1thr', 'lttng_2thr', 'lttng_4thr']
    lower_color = ['lightcoral', 'gray', 'chartreuse', 'red', 'black', 'forestgreen']
    upper = ['basel_8thr', 'basel_16thr', 'lttng_8thr', 'lttng_16thr']
    upper_color = ['deepskyblue', 'orange', 'mediumblue', 'saddlebrown']

    title='Meantime per syscalls for {} testcase'.format(graph_type)

    # Create a plot with 2 sub-plots
    f, arrax = plt.subplots(2, sharex=True, figsize=(12, 14))

    f.suptitle(title, fontsize=18)

    for (ax, sub, colors)  in zip(arrax, [lower, upper], [lower_color,upper_color]):
        curr_df = df[sub]
        ax.set_prop_cycle(cycler('color', colors))
        ax.plot(curr_df, marker='o')
        ax.set_ylim(0)
        ax.grid()
        ax.set_xlabel('Jenkins Build ID')
        ax.set_ylabel('Meantime per syscall [us]')
        ax.legend(labels=curr_df.columns.values, bbox_to_anchor=(1.2,1))
        ax.xaxis.set_major_locator(MaxNLocator(integer=True))

    plt.savefig('{}.png'.format(graph_type), bbox_inches='tight')

# Writes a file that contains commit id of all configurations shown in the
# plots
def create_metadata_file(res_dir):
    list_ = []
    for dirname, dirnames, res_files in os.walk('./'+res_dir):
        if len(dirnames) > 0:
            continue
        metadata = pd.read_csv(os.path.join(dirname, 'metadata.csv'))
        list_.append(metadata)

    df = pd.concat(list_)
    df.index=df.build_id
    df.sort_index(inplace=True)
    df.to_csv('metadata.csv', index=False)

#Iterates over a result directory and creates the plots for the different
#testcases
def create_plots(res_dir):
    df = pd.DataFrame()
    metadata_df = pd.DataFrame()
    list_ = []
    for dirname, dirnames, res_files in os.walk('./'+res_dir):
        if len(dirnames) > 0:
            continue
        metadata = pd.read_csv(os.path.join(dirname, 'metadata.csv'))

        for res in res_files:
            if res in 'metadata.csv':
                continue
            tmp = pd.read_csv(os.path.join(dirname, res))
            #Use the build id as the index for the dataframe for filtering
            tmp.index = metadata.build_id
            #Add the testcase name to the row for later filtering
            tmp['testcase'] = res.split('.')[0]
            list_.append(tmp)

        df = pd.concat(list_)
        df = convert_us_to_ns(df)
        df = rename_cols(df)
        df.sort_index(inplace=True)

    #Go over the entire dataframe by testcase and create a plot for each type
    for testcase in df.testcase.unique():
        df_testcase  = df.loc[df['testcase'] == testcase]
        create_plot(df=df_testcase, graph_type=testcase)

def main():
    res_path = sys.argv[1]
    create_plots(os.path.join(res_path))
    create_metadata_file(os.path.join(res_path))

if __name__ == '__main__':
    main()
