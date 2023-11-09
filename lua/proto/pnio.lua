------------------------------------------------------------------------
--- @file pnio.lua
--- @brief PROFINET_IO protocol utility.
--- Utility functions for the pnio_header structs
--- Includes:
--- - PROFINET_IO constants
--- - PROFINET_IO RT Header utility
--- - PROFINET_IO Cyclic RT utility
--- - Definition of PROFINET_IO packets
------------------------------------------------------------------------

local ffi = require "ffi"
require "proto.template"

-- Create a cached reference to functions, reducing the need to repeatedly look up the function in the global scope.
local initHeader = initHeader
local hton16 = hton16
local format = string.format
local cast = ffi.cast


local pnio = {}

pnio.headerFormat = [[
    uint16_t    frame_id;
    uint8_t     payload[]; // use with a noPayload proto stack
]]

pnio.headerVariableMember = "payload"



--- Ranges of PROFINET_RT FRAMEID. Values express the upper bound.

--- Time Syncronisation Frames
pnio.FRAMEID_UPPER_TIMESYNC = 0x00FF

--- RT_CLASS_3 Frames (IRTtop)
pnio.FRAMEID_UPPER_RT_3 = 0x7FFF

--- RT_CLASS_2 Frames (IRTflex)
pnio.FRAMEID_UPPER_RT_2 = 0xBFFF

--- RT_CLASS_3 Frames (RT/UDP)
pnio.FRAMEID_UPPER_RT_1 = 0xFBFF

--- Acyclic transmission "high"
pnio.FRAMEID_UPPER_AC_HIGH = 0xFCFF

--- Reserverd


local function isFrameTimeSync(frameId)
    return frameId > 0x0 and frameId <= pnio.FRAMEID_UPPER_TIMESYNC
end

local function isFrameRtClass3(frameId)
    return frameId > pnio.FRAMEID_UPPER_TIMESYNC and frameId <= pnio.FRAMEID_UPPER_RT_3
end

local function isFrameRtClass2(frameId)
    return frameId > pnio.FRAMEID_UPPER_RT_3 and frameId <= pnio.FRAMEID_UPPER_RT_2
end

local function isFrameRtClass1(frameId)
    return frameId > pnio.FRAMEID_UPPER_RT_2 and frameId <= pnio.FRAMEID_UPPER_RT_1
end

-- Cyclic are RT_CLASS_1, RT_CLASS_2, RT_CLASS_3
local function isFrameRTCyclic(frameId)
    return isFrameRtClass1(frameId) or
        isFrameRtClass2(frameId) or
        isFrameRtClass3(frameId)
end


------------------------------------------------------------------------------------
---- PROFINET_RT APDU_Status
------------------------------------------------------------------------------------
ffi.cdef [[
struct __attribute__((__packed__)) profinetRt_apdu_status {
	uint16_t cylce_counter;
	uint8_t data_status;
    uint8_t transfer_status;
};
]]
local profinetRtApduStatusType = ffi.typeof("struct profinetRt_apdu_status*")

--- @class profinetRt_apdu_status
local profinetRt_apdu_status = {}
profinetRt_apdu_status.__index = profinetRt_apdu_status

--- Set cycleCounter
--- @param cycle_counter number as uint16_t
function profinetRt_apdu_status:setCylceCounter(cycle_counter)
    self["cycle_counter"] = hton16(cycle_counter or 0)
end

--- Get CycleCounter
--- @return number cycle_counter as uint16_t
function profinetRt_apdu_status:getCycleCounter()
    ---@diagnostic disable-next-line: return-type-mismatch
    return hton16(self["cycle_counter"])
end

--- Set data_status
--- @param data_status number as uint8_t
function profinetRt_apdu_status:setDataStatus(data_status)
    self["data_status"] = data_status or 0
end

--- Get data_status
--- @return number dataStatus as unint8_t
function profinetRt_apdu_status:getDataStatus()
    return self["data_status"]
end

--- Set transfer_status
--- @param transfer_status number as unint8_t
function profinetRt_apdu_status:setTransferStatus(transfer_status)
    self["data_status"] = transfer_status or 0
end

--- Get transfer_status
--- @return number transfer_status as unint8_t
function profinetRt_apdu_status:getTransferStatus()
    return self["transfer_status"]
end

function profinetRt_apdu_status:getString()
    return ("APDU_Status, cycle_counter %d, data_stats %d, transfer_status %d").format(
        self:getCycleCounter(), self:getDataStatus(), self:getTransferStatus()
    )
end

ffi.metatype("struct profinetRt_apdu_status", profinetRt_apdu_status)

------------------------------------------------------------------------------------
---- PROFINET_RT Header
------------------------------------------------------------------------------------
--- @class pnioHeader
--- @field private frame_id number A uint16 number containing the FrameId
--- @diagnostic disable-next-line: assign-type-mismatch, missing-parameter
local pnioHeader = initHeader()
pnioHeader.__index = pnioHeader

--- Set the frameId.
--- @param frameId number as uint16
function pnioHeader:setFrameId(frameId)
    ---@diagnostic disable-next-line: assign-type-mismatch
    self.frame_id = hton16(frameId or pnio.FRAMEID_UPPER_RT_1)
end

--- Get the frameId.
function pnioHeader:getFrameId()
    return hton16(self.frame_id)
end

--- Get the ApduStatus of a clylic packet
--- @param pkt_len number Length of the packet. Needed because apdu_status is placed at the end of the packet
--- @return ffi.cdata*|nil
function pnioHeader:getApduStatus(pkt_len)
    -- Check if this rt packet is cyclic and thous has an apduStatus
    if not isFrameRTCyclic(self:getFrameId()) then
        return
    end

    local rt_data = self["payload"]
    -- Determin position of the APDUStatus
    -- If it does not work ffi.sizeof
    local sizeApduStatus = ffi.sizeof(profinetRtApduStatusType)
    local sizeFcs = 4
    local cycleCounterPos = pkt_len - sizeApduStatus - sizeFcs

    local apdu_status = cast(profinetRtApduStatusType, rt_data.unit8 + cycleCounterPos)
    return apdu_status
end

--- Retrieve the Frame type.
--- @return string FrameType.
function pnioHeader:getFrameString()
    local frame_id = self:getFrameId()
    local cleartext = ""

    if isFrameTimeSync(frame_id) then
        cleartext = "(TimeSync)"
    elseif isFrameRtClass1(frame_id) then
        cleartext = "(RT_CLASS_1)"
    elseif isFrameRtClass2(frame_id) then
        cleartext = "(RT_CLASS_2)"
    elseif isFrameRtClass3(frame_id) then
        cleartext = "(RT_CLASS_3)"
    else
        cleartext = "(unknown)"
    end

    return format("0x%04x %s", frame_id, cleartext)
end

------------------------------------------------------------------------------------
---- Functions for full header
------------------------------------------------------------------------------------

--- Set all members of the profinetRT header.
--- Per default, all members are set to default values specified in the respective set function.
--- The RT-User data will be filled with 36 bytes of 0 values for RT_CLASS_(1-3), in order to gain a valid packet.
--- Optional named arguments can be used to set a member to a user-provided value.
--- @param args table of named arguments. Available arguments:
---  FrameId
---  ApduStatus_CylceCounter    (Only if RT_CLASS_(1-3) (0 <= FrameId <= 0xFBFF))
---  ApduStatus_DataStatus      (Only if RT_CLASS_(1-3) (0 <= FrameId <= 0xFBFF))
---  ApduStatus_TransferStatus  (Only if RT_CLASS_(1-3) (0 <= FrameId <= 0xFBFF))
--- @param pre string Prefix for namedArgs. Default 'profinet_rt'.
--- @code
--- fill() -- only default values
--- fill{ xyz=1 } -- all members are set to default values with the exception of xyz, ...
--- @endcode
function pnioHeader:fill(args, pre)
    args = args or {}
    pre = pre or "profinet_rt"

    local frame_id = args[pre .. "FrameId"]
    self:setFrameId(frame_id)
end

--- Retrieve the values of all members.
--- @param pre string Prefix for namedArgs. Default 'profinet_rt'.
--- @return table namedArguments For a list of arguments see "See also".
--- @see profinetRtHeader.fill
function pnioHeader:get(pre)
    pre = pre or "profinet_rt"

    local args = {}
    local frame_id = self:getFrameId()
    args[pre .. "FrameId"] = frame_id

    -- local apdu_status = self:getApduStatus()
    -- if not apdu_status then
    --     return args
    -- end

    -- -- Add apdu_status to retured args
    -- args[pre .. "ApduStatus_CylceCounter"] = apdu_status:getCycleCounter()
    -- args[pre .. "ApduStatus_DataStatus"] = apdu_status:getDataStatus()
    -- args[pre .. "ApduStatus_TransferStatus"] = apdu_status:getTransferStatus()

    return args
end

function pnioHeader:getString()
    local string = "ProfinetRT, frame_id " .. self:getFrameString()

    -- -- Check if apduStatus is present and retieve
    -- local apduStatus = self:getApduStatus()

    -- if not apduStatus then
    --     return string
    -- end

    -- return string .. "   " ..
    --     apduStatus:getString()
    return string
end

--- Resolve which header comes after this one (in a packet)
--- This function must exist and is only used when get/dump is executed on
--- an unknown (mbuf not yet casted to e.g. tcpv6 packet) packet (mbuf)
--- @return nil next_header There is no next header
function pnioHeader:resolveNextHeader()
    return nil
end

------------------------------------------------------------------------------------
---- Metatypes
------------------------------------------------------------------------------------
pnio.metatype = pnioHeader

return pnio
