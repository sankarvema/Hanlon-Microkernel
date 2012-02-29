#!/usr/bin/env ruby

# this is rz_mk_control_server.rb
# it starts up a WEBrick server that can be used to control the Microkernel
# (commands to the Microkernel are invoked using Servlets running in the
# WEBrick instance)
#
# EMC Confidential Information, protected under EMC Bilateral Non-Disclosure Agreement.
# Copyright © 2012 EMC Corporation, All Rights Reserved
#
# @author Tom McSweeney

# adds a "require_relative" function to the Ruby Kernel if it
# doesn't already exist (used to deal with the fact that
# "require" is used instead of "require_relative" prior
# to Ruby v1.9.2)
unless Kernel.respond_to?(:require_relative)
  module Kernel
    def require_relative(path)
      require File.join(File.dirname(caller[0]), path.to_str)
    end
  end
end

require 'rubygems'
require 'logger'
require 'net/http'
require 'cgi'
require 'json'
require 'yaml'
require 'facter'
require_relative 'rz_mk_registration_manager'
require_relative 'fact_manager'

# setup a logger for our "Keep-Alive" server...
logger = Logger.new('/tmp/rz_mk_controller.log', 5, 1024*1024)
logger.level = Logger::DEBUG
logger.formatter = proc do |severity, datetime, progname, msg|
  "(#{severity}) [#{datetime.strftime("%Y-%m-%d %H:%M:%S")}]: #{msg}\n"
end

# setup the FactManager instance (we'll use this later, in our
# RzMkRegistrationManager constructor)
fact_manager = FactManager.new('/tmp/prev_facts.yaml')

# load the Microkernel Configuration, use the parameters in that configuration
# to control the
mk_config_file = '/tmp/mk_conf.yaml'
registration_manager = nil

if File.exist?(mk_config_file) then
  mk_conf = YAML::load(File.open(mk_config_file))

  # now, load a few items from that mk_conf map, first the URI for
  # the server
  razor_uri = mk_conf['mk']['razor_uri']

  # add the "node register" entry from that configuration map to
  # get the registration URI
  registration_uri = razor_uri + mk_conf['node']['register']

  # and add the 'node checkin' entry from that configuration map to
  # get the checkin URI
  checkin_uri = razor_uri + mk_conf['node']['checkin']


  # next, the time (in secs) to sleep between iterations of the main
  # loop (below)
  checkin_sleep = mk_conf['mk']['checkin_sleep']

  # next, the maximum amount of time to wait (in secs) the before starting
  # the main loop (below); a random number between zero and that amount of
  # time will be determined and used to ensure microkernel instances are
  # offset from each other when it comes to tasks like reporting facts to
  # the Razor server
  checkin_offset = mk_conf['mk']['checkin_offset']

  # this parameter defines which facts (by name) should be excluded from the
  # map that is reported during node registration
  exclude_pattern_str = mk_conf['facts']['exclude_pattern']
  exclude_pattern = nil
  if exclude_pattern_str && exclude_pattern_str.length > 2 then
    len = exclude_pattern_str.length
    exclude_pattern = Regexp.new(exclude_pattern_str[1,len-2])
  end
  registration_manager = RzMkRegistrationManager.new(registration_uri,
                                    exclude_pattern, fact_manager, logger)

else

  checkin_uri = nil
  checkin_sleep = 30
  checkin_offset = 5

end

msecs_sleep = checkin_sleep * 1000;
msecs_offset = checkin_offset * 1000;

# generate a random number between zero and msecs_offset and sleep for that
# amount of time
rand_secs = rand(msecs_offset) / 1000.0
logger.debug "Sleeping for #{rand_secs} seconds"
sleep(rand_secs)

idle = 'idle'

# and enter the main event-handling loop
loop do

  begin
    # grab the current time (used for calculation of the wait time and for
    # determining whether or not to register the node if the facts have changed
    # later in the event-handling loop)
    t1 = Time.now

    # if the checkin_uri was defined, then send a "checkin" message to the server
    if (checkin_uri) then
      uuid = Facter.hostname[2..-1]     # subset to remove the 'mk' prefix
      checkin_uri_string = checkin_uri + "?uuid=#{uuid}&last_state=#{idle}"
      uri = URI checkin_uri_string

      # then,handle the reply (could include a command that must be handled)
      response = Net::HTTP.get(uri)
      response_hash = JSON.parse(response)
      if response_hash['errcode'] == 0 then
        command = response_hash['response']['command_name']
        if command == "acknowledge" then
          logger.debug "Received #{command} from #{checkin_uri_string}"
        elsif registration_manager && command == "register" then
          registration_manager.register_node(idle)
        elsif command == "reboot" then
          # reboots the node, NOW...no sense in logging this since the "filesystem"
          # is all in memory and will disappear when the reboot happens
          %x[sudo reboot now]
        end
      end
    end

    # if we haven't saved the facts since we started this iteration, then we
    # need to check to see whether or not the facts have changed since our last
    # registration; if so, then we need to re-register this node
    if registration_manager && t1 > fact_manager.last_saved_timestamp then
      registration_manager.register_node_if_changed(idle)
    end

  rescue
    logger.debug("An exception occurred: #{$!}")
  end

  # check to see how much time has elapsed, sleep for the time remaining
  # in the msecs_sleep time window
  t2 = Time.now
  msecs_elapsed = (t2 - t1) * 1000
  if msecs_elapsed < msecs_sleep then
    secs_sleep = (msecs_sleep - msecs_elapsed)/1000.0
    logger.debug "Time remaining: #{secs_sleep} seconds..."
    sleep(secs_sleep) if secs_sleep >= 0.0
  end

end
