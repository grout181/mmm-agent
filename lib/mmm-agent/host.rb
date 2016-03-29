require 'uri'

class MmmAgent::Host

  attr_accessor :cpu, :gpu
  
  def initialize(options)
    # Store for later
    @options = options
    
    # Get informations about the CPU
    @cpu = MmmAgent::Cpu.new
    
    # Get informations about the GPUs (Nvidia only ATM)
    @gpu = Array.new
    (0..nvidia_gpus_count - 1).each do |id|
      @gpu[ id ] = MmmAgent::Gpu.new( id )
    end
    
    # Create MiningOperation object
    @mining_operation = MmmAgent::MiningOperation.new(self)
    
    # Log hardware informations
    Log.info "Hostname is #{options.hostname}"
    Log.info "Found #{@cpu.human_readable}"
    Log.info "Found #{@gpu.size} GPUs:"
    @gpu.each do |gpu|
      Log.info "#{gpu.model} (#{gpu.uuid})"
    end

    # Get a connection to the mmm-server
    @server = MmmAgent::ServerConnection.new(@options)
  end

  def nvidia_gpus_count
    return @nvidia_gpus_count if @nvidia_gpus_count
    @nvidia_gpus_count = `lspci | grep VGA | grep -c NVIDIA`.to_i
  end
  
  def has_nvidia_gpus?
    nvidia_gpus_count > 0
  end
  
  def get_rig_url
    return @rig_url if !@rig_url.nil?
  
    data = @server.get('/rigs.json')
    data.each do |rig|
      if rig['hostname'] == @options.hostname
        uri = URI::parse(rig['url'])
        @rig_url = uri.path
      end
    end
    @rig_url = register_rig if @rig_url.nil?
    return @rig_url
  end
  
  def register_rig
    Log.notice "Creating the Rig on mmm-server"
    newRig = {
      :hostname => @options.hostname,
      :power_price => 0,
      :power_currency => 'USD'
    }
    data = @server.post('/rigs.json', newRig)
    id = data['rig']['id']['$oid']
    "/rigs/#{id}.json"
  end
  
  def update_rig_mining_operation
    data = @server.get(get_rig_url)
    if data['rig']['what_to_mine'].nil?
      Log.warning "No mining operation. Go configure your rig on #{@options.server_url}"
      return
    end
    @mining_operation.update(data['rig']['what_to_mine'])
    uri = URI::parse(data['rig']['hashrate_url'])
    return uri.path
  end
  
  def keep_mining_operation_up_to_date(stats_url)
    while true
      begin
        sleep 900
        send_statistics(stats_url)
        clear_statistics
        Log.info "Getting best mining operation from server"
        stats_url = update_rig_mining_operation
      rescue StandardError => e
        Log.warning "Error contacting mmm-server: #{e.to_s}"
      end
    end
  end

  def send_statistics(stats_url)
    stats = {
      :rate         => get_hashrate,
      :power_usage  => get_power_usage
    }
    Log.notice "Sending stats: #{stats[:rate]} H/s at #{stats[:power_usage]} W"
    @server.put(stats_url, stats) unless stats[:rate] == 0
  end
  
  def clear_statistics
    Log.info "Clearing statistics for the next mining round"
    @gpu.each do |g|
      g.clear_statistics
    end    
  end
  
  def start_mining
    # Get the first mining operation we will be working on
    stats_url = update_rig_mining_operation
    
    # Keep updating it periodicaly from the server
    Thread.new{keep_mining_operation_up_to_date(stats_url)}
    
    # Run the miner command in the background
    @mining_operation.run_miner
  end

  private

    def get_hashrate
      hashrate = 0
      @gpu.each do |g|
        hashrate += g.hashrate.avg.to_i
      end
      hashrate
    end
    
    def get_power_usage
      power_draw = 0
      @gpu.each do |g|
        power_draw += g.power_draw.avg.to_i
      end
      power_draw
    end
  
end
