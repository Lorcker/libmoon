local lm     = require "libmoon"
local device = require "device"
local memory = require "memory"
local stats  = require "stats"

function configure(parser)
    parser:argument("devs", "Device(s) to use."):args(1)
    parser:option("-t --threads", "Number of threads."):convert(tonumber):default(1)
    local args = parser:parse()
    return args
end

function master(args)
    for portId in args.devs:gmatch("%d+") do
        local dev = device.config { port = tonumber(portId), txQueues = args.arp and 2 or 1, rxQueues = args.threads, rssQueues = args.threads, stripVlan = (not args.vlans) }
        device.waitForLinks()
        stats.startStatsTask { rxDevices = { dev } }

        for i = 1, args.threads do
            lm.startTask("dumper", dev:getRxQueue(i - 1), args, i, portId)
        end
    end
    lm.waitForTasks()
end

function dumper(queue, args, threadId, devId)
    local bufs = memory.createbufArray()
    while lm.running() do
        -- tryRecv
        local rx = queue:tryRecv(bufs, 100)
        local batchTime = lm.getTime()
        for i = 1, rx do
            local buf = bufs[i]

            --- @type pkt
            local packet = buf:get()
            if packet.pnio then
                -- Packet is pnio packet and hat the accoring functions
                --- @type profinetRt_apdu_status
                local apdu_status = packet.pnio:getApduStatus(packet:getSize())
                local total_string = packet.eth:getString() .. packet.pnio:getString() .. apdu_status:getString()
                print(total_string)
            end

            -- buf:dump()

            buf:free()
        end
    end
end
