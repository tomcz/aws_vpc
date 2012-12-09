#!/bin/sh

bundle check || bundle install

if [ "$1" == "irb" ]; then
  bundle exec $@
elif [ "$1" == "rake" ]; then
  bundle exec $@
else
  bundle exec rake $@
fi
