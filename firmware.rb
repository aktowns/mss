#!/usr/bin/env ruby 
require 'bindata'
require 'zlib'
require 'pry'

# CFE Firmware (BRCM)
#  0                   1                   2                   3   
#  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 
# +---------------------------------------------------------------+
# |                     magic number ('BCRM')                     |
# +---------------------------------------------------------------+
# |                      Number of Sections                       |
# +---------------+---------------+-------------------------------+
# |                         TYPE_TAG (21)                         |
# +---------------+---------------+-------------------------------+
# |                           Tag Size                            |
# +---------------+---------------+-------------------------------+
# |                        TYPE_FLASH (18)                        |
# +---------------+---------------+-------------------------------+
# |                          Flash Size                           |
# +---------------+---------------+-------------------------------+
# |                         TYPE_DISK (21)                        |
# +---------------+---------------+-------------------------------+
# |                           Disk Size                           |
# +---------------+---------------+-------------------------------+
# |                                                               |
# |                            TAG Data                           |
# |                           (Tag Size)                          |
# |                                                               |
# +---------------+---------------+-------------------------------+
# |                                                               |
# |                        FLASH DATA (TRXv1)                     |
# |                           (Flash Size)                        |
# |                                                               |
# +---------------+---------------+-------------------------------+
# |                                                               |
# |                       DISK Data (TRXv1)                       |
# |                          (Disk Size)                          |
# |                                                               |
# +---------------+---------------+-------------------------------+
# http://www.openmss.org/Hardware/MssExtractFirmware

# TRXv1
#  0                   1                   2                   3   
#  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 
# +---------------------------------------------------------------+
# |                     magic number ('HDR0')                     |
# +---------------------------------------------------------------+
# |                  length (header size + data)                  |
# +---------------+---------------+-------------------------------+
# |                       32-bit CRC value                        |
# +---------------+---------------+-------------------------------+
# |           TRX flags           |          TRX version          |
# +-------------------------------+-------------------------------+
# |                      Partition offset[0]                      |
# +---------------------------------------------------------------+
# |                      Partition offset[1]                      |
# +---------------------------------------------------------------+
# |                      Partition offset[2]                      |
# +---------------------------------------------------------------+
# http://wiki.openwrt.org/doc/techref/header

NAS_MAGIC = 1296257602 # bcrm 
NAS_TAG   = 21
NAS_FLASH = 18
NAS_DISK  = 19

TRX_MAGIC = 810697800  # hdr0

class Partition < BinData::Record
  endian :little 
  mandatory_parameter :size

  string :data, :read_length => :size
end

class TRX < BinData::Record 
  endian :little 
  hide   :magic 

  uint32 :magic, assert: TRX_MAGIC
  uint32 :image_size
  uint32 :crc32
  uint16 :trx_flags, value: 0
  uint16 :trx_version, value: 1

  array :offsets, :type => :uint32, initial_length: 3
  array :partitions, initial_length: 3, :type => [:partition, {
    :size => lambda { 
      if (offsets[index] == 0) 
        0
      elsif (index == 0 && offsets[index+1] != 0) 
        #puts "1: #{offsets[index+1] - 28}/#{image_size}"
        offsets[index+1] - 28
      elsif (offsets[index+1] == 0 && index != 0) 
        #puts "2: #{(image_size - offsets.inject{|x,y|x+y}) + 28}/#{image_size}"
        (image_size - offsets.inject{|x,y|x+y}) + 28
      elsif (offsets[index+1] == 0)
        #puts "3: #{image_size - offsets.inject{|x,y|x+y}}/#{image_size}"
        (image_size - offsets.inject{|x,y|x+y})
      end
    }
  }]
end

class SectionType < BinData::Primitive
  endian :little
  uint32 :type 

  def get
    case self.type
    when NAS_TAG then "TAG"
    when NAS_FLASH then "FLASH"
    when NAS_DISK then "DISK"
    else throw "Unknown header type encountered: #{self.type}"
    end
  end
end

class NasSection < BinData::Record
  endian :little 
  mandatory_parameter :size

  string :data, :length => :size
end

class NasHeader < BinData::Record 
  endian :little
  hide   :pad_0

  section_type :section_type
  uint32 :section_size
  uint32 :pad_0, assert: 0x000000
end

class NasFirmware < BinData::Record 
  endian :little
  hide   :magic

  uint32 :magic, assert: NAS_MAGIC
  uint32 :sections_count
  array  :section_headers, :type => :nas_header, :initial_length => :sections_count

  array :sections, 
    :initial_length => :sections_count, 
    :type => [:nas_section, {
      :size => lambda { section_headers[index].section_size }
    }]
end

f = File.open(ARGV[0], 'r') { |io| NasFirmware.read(io) }
sections = {}
f.section_headers.each_with_index do |header, index|
  sections[header.section_type.get] = f.sections[index].data
end


puts sections["TAG"]
#BinData::trace_reading do
  flash = TRX.read(sections["FLASH"])
  disk  = TRX.read(sections["DISK"])

  puts "-- OFFSETS --"
  p flash.offsets 
  p disk.offsets 
  puts "--"
  kernel = flash.partitions[0].data
  cramfs = flash.partitions[1].data
  mainfs = disk.partitions[0].data

  puts "Extracting kernel: vmlinuz.gz"
  File.open('vmlinuz.gz', 'w') {|io| io.puts kernel }
  puts "Extracting cramfs: flash.cramfs"
  File.open('flash.cramfs', 'w') {|io| io.puts cramfs }
  puts "Extracting mainfs: main.cramfs"
  File.open('main.cramfs', 'w') {|io| io.puts mainfs }
#end




puts "Creating new firmware"

flash_type = SectionType.new
flash_type.type = NAS_FLASH

disk_type  = SectionType.new
disk_type.type = NAS_DISK

firmware = NasFirmware.new
flash    = NasHeader.new(section_type: flash_type)
disk     = NasHeader.new(section_type: disk_type)

kern = Partition.new(data: kernel)
flas = Partition.new(data: cramfs)
main = Partition.new(data: mainfs)

flash_size = kern.size + flas.size 
crc32 = Zlib::crc32(kernel + cramfs)

TRX.new(size: flash_size)

flash_section = NasSection.new(size: kernel.length + cramfs.length)


firmware.section_headers = [flash, disk]
firmware.sections_count = 2

p firmware
