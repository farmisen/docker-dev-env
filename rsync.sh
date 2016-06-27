#!/usr/bin/env bash

gem install bundler && bundle && ./rsync.rb -f $1