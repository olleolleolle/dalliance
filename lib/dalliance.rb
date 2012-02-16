require 'dalliance/version'

require 'dalliance/progress_meter'

module Dalliance
  extend ActiveSupport::Concern
  
  class << self
    def options
      @options ||= {
        :background_processing => true,
        :dalliance_progress_meter_total_count_method => :dalliance_progress_meter_total_count
      }
    end
    
    def background_processing?
      options[:background_processing]
    end
    
    def background_processing=(value)
      options[:background_processing] = value
    end
    
    def configure
      yield(self) if block_given?
    end
  end
  
  included do
    has_one :dalliance_progress_meter, :as => :dalliance_progress_model, :class_name => '::Dalliance::ProgressMeter'
    
    serialize :dalliance_error_hash, Hash
    
    #BEGIN state_machine(s)
    scope :pending, where(:dalliance_status => 'pending')
    scope :processing, where(:dalliance_status => 'processing')
    scope :processing_error, where(:dalliance_status => 'processing_error')
    scope :completed, where(:dalliance_status => 'completed')

    state_machine :dalliance_status, :initial => :pending do
      state :pending
      state :processing
      state :processing_error
      state :completed

      event :queue_dalliance do
        transition :processing_error => :pending
      end

      event :start_dalliance do
        transition :pending => :processing
      end

      event :error_dalliance do
        transition :processing => :processing_error
      end

      event :finish_dalliance do
        transition :processing => :completed
      end
    end
    #END state_machine(s)
  end
  
  module ClassMethods
    def dalliance_status_in_load_select_array
      state_machine(:dalliance_status).states.map {|state| [state.human_name, state.name] }
    end
  end
  
  def error_or_completed?
    processing_error? || completed?
  end
  
  def pending_or_processing?
    pending? || processing?
  end
  
  #Force backgound_processing w/ true
  def dalliance_background_process(backgound_processing = nil)
    if backgound_processing || (backgound_processing.nil? && Dalliance.background_processing?)
      delay.dalliance_process(true)
    else
      dalliance_process(false)
    end
  end
  
  #backgound_processing == false will re-raise any exceptions
  def dalliance_process(backgound_processing = false)
    begin
      start_dalliance!

      build_dalliance_progress_meter(:total_count => calculate_dalliance_progress_meter_total_count).save!
      
      self.send(self.class.dalliance_options[:dalliance_method])

      finish_dalliance!
    rescue StandardError => e
      #Save the error for future analysis...
      self.dalliance_error_hash = {:error => e, :message => e.message, :backtrace => e.backtrace}

      error_dalliance!
      
      #Don't raise the error if we're backgound_processing...
      raise e unless backgound_processing
    ensure
      if dalliance_progress_meter
        dalliance_progress_meter.destroy
      end
    end
  end
  
  def dalliance_progress
    if completed?
      100
    else
      if dalliance_progress_meter
        dalliance_progress_meter.progress
      else
        0
      end
    end
  end

  #If the progress_meter_total_count_method is not implemented just use 1...
  def calculate_dalliance_progress_meter_total_count
    if respond_to?(self.class.dalliance_options[:dalliance_progress_meter_total_count_method])
      self.send(self.class.dalliance_options[:dalliance_progress_meter_total_count_method])
    else
      1
    end
  end
end

#http://yehudakatz.com/2009/11/12/better-ruby-idioms/
class ActiveRecord::Base
  def self.dalliance(*args)
    options = args.last.is_a?(Hash) ? Dalliance.options.merge(args.pop) : Dalliance.options
    
    case args.length
    when 1
      options[:dalliance_method] = args[0]
    else 
      raise ArgumentError, "Incorrect number of Arguements provided" 
    end
    
    cattr_accessor :dalliance_options
    self.dalliance_options = options
    include Dalliance
  end
end