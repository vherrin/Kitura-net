/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Foundation
import KituraSys

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

class FastCGIRecordParser {
    
    // Variables
    //
    var version : UInt8 = 0
    var type : UInt8 = 0
    var requestId : UInt16 = 0
    var role : UInt16 = 0
    var flags : UInt8 = 0
    var headers : [Dictionary] = Array<Dictionary<String,String>>()
    var data : NSData? = nil
    var appStatus : UInt32 = 0
    var protocolStatus : UInt8 = 0
    
    var keepalive : Bool {
        return self.flags & FastCGI.Constants.FCGI_KEEP_CONN == 0 ? false : true
    }
    
    // Internal Variables
    //
    private var contentLength : UInt16 = 0
    private var paddingLength : UInt8 = 0
    private var pointer : Int = 0
    private var buffer : NSData
    private var bufferBytes : UnsafePointer<UInt8>
    
    // Pointer Helper Methods
    //
    // Advance the pointer, returning the pointer value as it
    // existed when this method was first called. Throws an 
    // exception if we advance beyond the end of the buffer
    // to prevent reading memory out of bounds.
    //
    func advance() throws -> Int {
        
        guard self.pointer < self.buffer.length else {
            throw FastCGI.RecordErrors.bufferExhausted
        }
        
        let r = self.pointer
        self.pointer += 1
        return r
    }
    
    //
    // Skip the pounter ahead, returning nothing. We only
    // throw an exception if thsi call pushes the pointer past
    // the valid bounds.
    //
    func skip(_ count: Int) throws {
        
        self.pointer += count
        
        // because we're skipping, it's ok to be pointer=length because we 
        // may never be reading again. but pointer=(length+x) is bad (where x>0)
        // because it means there aren't the bytes we expected
        //
        guard self.pointer <= self.buffer.length else {
            throw FastCGI.RecordErrors.bufferExhausted
        }
    }
    
    //
    // Helper to turn UInt16 from network byte order to local byte order,
    // which is typically Big to Little.
    //
    private static func getLocalByteOrderSmall(from networkOrderedBytes: UInt16) -> UInt16 {
        #if os(Linux)
            return Glibc.ntohs(networkOrderedBytes)
        #else
            return CFSwapInt16BigToHost(networkOrderedBytes)
        #endif
    }
    
    //
    // Helper to turn UInt32 from network byte order to local byte order,
    // which is typically Big to Little.
    //
    private static func getLocalByteOrderLarge(from networkOrderedBytes: UInt32) -> UInt32 {
        #if os(Linux)
            return Glibc.ntohl(networkOrderedBytes)
        #else
            return CFSwapInt32BigToHost(networkOrderedBytes)
        #endif
    }
    
    // Initialize
    //
    init(_ data: NSData) {
        self.buffer = data
        self.bufferBytes = UnsafePointer<UInt8>(data.bytes)
    }
    
    //
    // Parse FastCGI Version
    //
    private func parseVersion() throws {
        self.version = self.bufferBytes[try advance()]
        
        guard self.version == FastCGI.Constants.FASTCGI_PROTOCOL_VERSION else {
            throw FastCGI.RecordErrors.invalidVersion
        }
    }
    
    // Parse record type.
    //
    private func parseType() throws {
        
        self.type = self.bufferBytes[try advance()]
        
        switch self.type {
        case FastCGI.Constants.FCGI_BEGIN_REQUEST,
             FastCGI.Constants.FCGI_END_REQUEST,
             FastCGI.Constants.FCGI_PARAMS,
             FastCGI.Constants.FCGI_STDIN,
             FastCGI.Constants.FCGI_STDOUT:
            break
        
        default:
            throw FastCGI.RecordErrors.invalidType
        }
        
    }
    
    // Parse request ID
    //
    private func parseRequestId() throws {
        
        let requestIdBytes1 = self.bufferBytes[try advance()]
        let requestIdBytes0 = self.bufferBytes[try advance()]
        let requestIdBytes : [UInt8] = [ requestIdBytes1, requestIdBytes0 ]
        
        self.requestId = FastCGIRecordParser.getLocalByteOrderSmall(from: UnsafePointer<UInt16>(requestIdBytes).pointee)
        
    }

    // Parse content length.
    //
    private func parseContentLength() throws {
        
        let contentLengthBytes1 = self.bufferBytes[try advance()]
        let contentLengthBytes0 = self.bufferBytes[try advance()]
        let contentLengthBytes : [UInt8] = [ contentLengthBytes1, contentLengthBytes0 ]
        
        self.contentLength = FastCGIRecordParser.getLocalByteOrderSmall(from: UnsafePointer<UInt16>(contentLengthBytes).pointee)
        
    }
    
    // Parse padding length
    //
    private func parsePaddingLength() throws {
        self.paddingLength = self.bufferBytes[try advance()]
    }

    // Parse a role
    //
    private func parseRole() throws {
        
        let roleByte1 = self.bufferBytes[try advance()]
        let roleByte0 = self.bufferBytes[try advance()]
        let roleBytes : [UInt8] = [ roleByte1, roleByte0 ]
        
        self.role = FastCGIRecordParser.getLocalByteOrderSmall(from: UnsafePointer<UInt16>(roleBytes).pointee)
        self.flags = self.bufferBytes[try advance()]

        guard self.role == FastCGI.Constants.FCGI_RESPONDER else {
            throw FastCGI.RecordErrors.unsupportedRole
        }
        
    }
    
    // Parse an app status
    //
    private func parseAppStatus() throws {
        
        let appStatusByte3 = self.bufferBytes[try advance()]
        let appStatusByte2 = self.bufferBytes[try advance()]
        let appStatusByte1 = self.bufferBytes[try advance()]
        let appStatusByte0 = self.bufferBytes[try advance()]
        let appStatusBytes : [UInt8] = [ appStatusByte3, appStatusByte2, appStatusByte1, appStatusByte0 ]
        
        self.appStatus = FastCGIRecordParser.getLocalByteOrderLarge(from: UnsafePointer<UInt32>(appStatusBytes).pointee)
    
    }
    
    // Parse a protocol status
    //
    private func parseProtocolStatus() throws {
        self.protocolStatus = self.bufferBytes[try advance()]
    }
    
    // Parse raw data from a data record
    //
    private func parseData() throws {
        if self.contentLength > 0 {
            self.data = NSData(bytes: self.bufferBytes + pointer, length: Int(self.contentLength))
            try skip(Int(self.contentLength))
        } else {
            self.data = NSData()
        }
    }
    
    //
    // The following functions parse the parameter blocks.
    // Because parameter blocks can be encoded sequentially
    // in a single record this is more complex than simply 
    // extracting blocks from a single record - hance the 
    // extra functions involved.
    //
    
    //
    // The parameter name/value length encoding scheme used by FastCGI
    // is interesting. Basically, it lets 1 byte be used to encode lengths
    // less than 127 bytes, but allocates 4 bytes to encode the length
    // of anything larger. We determine what state we're in by checking
    // the higher order bit of the first byte in the length. off = 127 or less,
    // on = 128 or larger.
    //
    // If we are using 4 bytes for a length value, we need to mask
    // the first byte with 0x7f when assembling it back into a 32-bit length
    // value.
    //
    //
    private func parseParameterLength() throws -> Int {
        
        let lengthPeek : UInt8 = self.bufferBytes[try advance()]
        
        if lengthPeek >> 7 == 0 {
            
            // The parameter name/value length is encoded into a 
            // single byte.
            //
            return Int(lengthPeek)
            
        } else {
            
            // The parameter name/value lenght is encoded into 4
            // bytes, the first of which we read needs to be 
            // masked to created the correct value.
            //
            let lengthByteB3 : UInt8 = lengthPeek
            let lengthByteB2 : UInt8 = self.bufferBytes[try advance()]
            let lengthByteB1 : UInt8 = self.bufferBytes[try advance()]
            let lengthByteB0 : UInt8 = self.bufferBytes[try advance()]
            let lengthBytes : [UInt8] = [ lengthByteB3 & 0x7f, lengthByteB2, lengthByteB1, lengthByteB0 ]

            return Int(FastCGIRecordParser.getLocalByteOrderLarge(from: UnsafePointer<UInt32>(lengthBytes).pointee))
        }
        
    }
    
    // Parse a parameter block
    //
    private func parseParameters() throws {
        
        guard self.contentLength > 0 else {
            return
        }
        
        var contentRemaining : Int = Int(self.contentLength)
        
        repeat {
            
            let initialPointer : Int = self.pointer
            let nameLength : Int = try self.parseParameterLength()
            let valueLength : Int = try self.parseParameterLength()
            
            // capture the parameter name
            //
            guard nameLength > 0 else {
                // this doesn't seem likely - web server sent an empty parameter
                // name length, which is not allowed and has no point. error state.
                //
                throw FastCGI.RecordErrors.emptyParameters
            }
            
            let currentPointer : Int = pointer
            try skip(nameLength)
            let nameData = NSData(bytes: self.bufferBytes + currentPointer, length: nameLength)
            
            guard let nameString = StringUtils.fromUtf8String(nameData) else {
                // the data received from the web server couldn't be transcoded
                // to a UTF8 string. This is an error.
                //
                throw FastCGI.RecordErrors.emptyParameters
            }
            
            guard nameString.characters.count > 0 else {
                // The data received form the web server existed and transcoded,
                // but someone resulted in a string of zero length. 
                // Strange, but an error none the less.
                //
                throw FastCGI.RecordErrors.emptyParameters
            }
            
            // capture the parameter value
            //
            if valueLength > 0 {
                
                let currentPointer : Int = pointer
                try skip(valueLength)
                let valueData = NSData(bytes: self.bufferBytes + currentPointer, length: valueLength)
                
                guard let valueString = StringUtils.fromUtf8String(valueData) else {
                    // a value was supposed to have been provided but decoding it
                    // from the data failed.
                    //
                    throw FastCGI.RecordErrors.emptyParameters
                }
                
                // Done - store our paramter with the decoded value.
                //
                self.headers.append(["name": nameString, "value": valueString])
            }
            else {
                // Done - store our paramter with the blank value (perfectly OK)
                //
                self.headers.append(["name": nameString, "value": ""])
            }
            
            // adjust our position
            //
            contentRemaining = contentRemaining - (self.pointer - initialPointer)
            
        }
        while contentRemaining > 0
        
    }
    
    // Skip any padding indicated, then return the unused portion
    // of our data buffer. We're done reading this record.
    //
    private func skipPaddingThenReturn() throws -> NSMutableData {
        
        if self.paddingLength > 0 {
            try skip(Int(self.paddingLength))
        }
        
        let remainingBufferBytes = self.buffer.length - self.pointer
        
        if remainingBufferBytes == 0 {
            return NSMutableData()
        } else {
            return NSMutableData(bytes: buffer.bytes + self.pointer, length: remainingBufferBytes)
        }
        
    }
    
    // Parser the data, return any extra
    //
    func parse() throws -> NSMutableData {
        
        // Make parser go now!
        //
        // Parse a record from the data stream, returning any 
        // data that wasn't needed after decoding the record.
        //
        try parseVersion()
        try parseType()
        try parseRequestId()
        try parseContentLength()
        try parsePaddingLength()
        try skip(1)
        
        switch self.type {
        case FastCGI.Constants.FCGI_BEGIN_REQUEST:
            try parseRole()
            try skip(5)
            break
            
        case FastCGI.Constants.FCGI_END_REQUEST:
            try parseAppStatus()
            try parseProtocolStatus()
            try skip(3)
            break
            
        case FastCGI.Constants.FCGI_PARAMS:
            try parseParameters()
            break
            
        default:
            // either STDIN or STDOUT
            try parseData()
            break
        }
        
        // return new data object representing any data
        // not part of the parsed record
        return try skipPaddingThenReturn()
    }
    
    
}