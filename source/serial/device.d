 // Copyright 2013 Gushcha Anton
/*
   Boost Software License - Version 1.0 - August 17th, 2003

   Permission is hereby granted, free of charge, to any person or organization
   obtaining a copy of the software and accompanying documentation covered by
   this license (the "Software") to use, reproduce, display, distribute,
   execute, and transmit the Software, and to prepare derivative works of the
   Software, and to permit third-parties to whom the Software is furnished to
   do so, all subject to the following:

   The copyright notices in the Software and this entire statement, including
   the above license grant, this restriction and the following disclaimer,
   must be included in all copies of the Software, in whole or in part, and
   all derivative works of the Software, unless such copies or derivative
   works are solely in the form of machine-executable object code generated by
   a source language processor.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
   SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
   FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
   ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
   DEALINGS IN THE SOFTWARE.
 */
// Written in D programming language
/**
 *   Module providing instruments to work with serial port on Windows and Posix
 *   OS. SerialPort class can enumerate available serial ports (works robust only 
 *   on Windows), check available baud rates. 
 *   
 *   Example:
 *   --------
 *   auto com = new SerialPort("COM1"); // ttyS0 on GNU/Linux, for instance
 *   string test = "Hello, World!";
 *   com.write(test.ptr);
 *   
 *   ubyte[13] buff;
 *   com.read(buff);
 *   writeln(cast(string)buff);
 *   --------
 *
 *   Note: Some points were extracted from Tango D2 library.
 *   TODO: Serial port tweaking, asynchronous i/o.
 */
module serial.device;

import std.conv;
import std.stdio;
import std.string;
import core.time;

version(Posix)
{
   import core.sys.posix.unistd;
   import core.sys.posix.termios;
   import core.sys.posix.fcntl;
   import core.sys.posix.sys.select;
   import std.algorithm;
   import std.file;

   enum B57600 = 57_600;
   enum B115200 = 115_200;

   alias core.sys.posix.unistd.read posixRead;
   alias core.sys.posix.unistd.write posixWrite;
   alias core.sys.posix.unistd.close posixClose;
}
version(Windows)
{
   import core.sys.windows.windows;
   import std.bitmanip;
}

/**
 *   Represents allowed baud rate speeds for serial port.
 */
enum BaudRate : uint
{
   BR_110    = 110,
   BR_300    = 300,
   BR_600    = 600,
   BR_1200   = 1200,
   BR_2400   = 2400,
   BR_4800   = 4800,
   BR_9600   = 9600,
   BR_19200  = 19_200,
   BR_38400  = 38_400,
   BR_57600  = 57_600,
   BR_115200 = 115_200,
   BR_UNKNOWN  // refers to unknown baud rate
}
/**
 *   Thrown when trying to setup serial port with
 *   unsupported baud rate by current OS.
 */
class SpeedUnsupportedException : Exception
{
   BaudRate speed;

   this(BaudRate spd)
   {
      speed = spd;
      super(text("Speed ", spd, " is unsupported!"));
   }
}
// The members of enums should be camelCased
//http://dlang.org/dstyle.html
enum Parity {
   none,
   odd,
   even
}
class ParityUnsupportedException : Exception
{
   Parity parity;

   this(Parity p)
   {
      parity = p;
      super(text("Parity ", p, " is unsupported!"));
   }
}

/**
 *   Thrown when setting up new serial port parameters has failed.
 */
class InvalidParametersException : Exception 
{
   string port;

   @safe pure nothrow this(string port, string file = __FILE__, size_t line = __LINE__)
   {
      this.port = port;
      super("One of serial port "~ port ~ " parameters is invalid!", file, line);
   }
}

/**
 *   Thrown when tried to open invalid serial port file.
 */
class InvalidDeviceException : Exception
{
   string port;

   @safe pure nothrow this(string port, string file = __FILE__, size_t line = __LINE__)
   {
      this.port = port;
      super(text("Failed to open serial port with name ", port, "!"), file, line);
   }
}

/**
 *   Thrown when trying to accept closed device.
 */
class DeviceClosedException : Exception 
{
   @safe pure nothrow this(string file = __FILE__, size_t line = __LINE__)
   {
      super("Tried to access closed device!", file, line);
   }
}

/**
 *	Thrown when read/write operations failed due timeout.
 *
 *   Exception carries useful info about number of read/wrote bytes until
 *   timeout occurs. It takes sense only for Windows, as posix version 
 *   won't start reading until the port is empty.
 */
class TimeoutException : Exception
{
   /**
    *   Transfers problematic $(B port) name and $(B size) of read/wrote bytes until
    *   timeout.
    */
   @safe pure nothrow this(string port, size_t size, string file = __FILE__, size_t line = __LINE__)
   {
      this.size = size;
      super("Timeout is expires for serial port '"~port~"'", file, line);
   }

   size_t size;
}

/**
 *   Thrown when reading from serial port is failed.
 */
class DeviceReadException : Exception 
{
   string port;

   @safe pure nothrow this(string port, string file = __FILE__, size_t line = __LINE__)
   {
      this.port = port;
      super("Failed to read from serial port with name " ~ port, file, line);
   }
}

/**
 *   Thrown when writing to serial port is failed.
 */
class DeviceWriteException : Exception 
{
   string port;

   @safe pure nothrow this(string port, string file = __FILE__, size_t line = __LINE__)
   {
      this.port = port;
      super("Failed to write to serial port with name " ~ port, file, line);
   }
}

version(Windows)
{
   enum NOPARITY    = 0x0;
   enum EVENPARITY  = 0x2;
   enum MARKPARITY  = 0x3;
   enum ODDPARITY   = 0x1;
   enum SPACEPARITY = 0x4;

   enum ONESTOPBIT   = 0x0;
   enum ONE5STOPBITS = 0x1;
   enum TWOSTOPBITS  = 0x2;

   struct DCB 
   {
      DWORD DCBlength;
      DWORD BaudRate;

      mixin(bitfields!(
               DWORD, "fBinary",           1,
               DWORD, "fParity",           1,
               DWORD, "fOutxCtsFlow",      1,
               DWORD, "fOutxDsrFlow",      1,
               DWORD, "fDtrControl",       2,
               DWORD, "fDsrSensitivity",   1,
               DWORD, "fTXContinueOnXoff", 1,
               DWORD, "fOutX",             1,
               DWORD, "fInX",              1,
               DWORD, "fErrorChar",        1,
               DWORD, "fNull",             1,
               DWORD, "fRtsControl",       2,
               DWORD, "fAbortOnError",     1,
               DWORD, "fDummy2",           17));

      WORD  wReserved;
      WORD  XonLim;
      WORD  XoffLim;
      BYTE  ByteSize;
      BYTE  Parity;
      BYTE  StopBits;
      ubyte  XonChar;
      ubyte  XoffChar;
      ubyte  ErrorChar;
      ubyte  EofChar;
      ubyte  EvtChar;
      WORD  wReserved1;
   }

   struct COMMTIMEOUTS
   {
      DWORD ReadIntervalTimeout;
      DWORD ReadTotalTimeoutMultiplier;
      DWORD ReadTotalTimeoutConstant;
      DWORD WriteTotalTimeoutMultiplier;
      DWORD WriteTotalTimeoutConstant;
   }

   extern(Windows) 
   {
      bool GetCommState(HANDLE hFile, DCB* lpDCB);
      bool SetCommState(HANDLE hFile, DCB* lpDCB);
      bool SetCommTimeouts(HANDLE hFile, COMMTIMEOUTS* lpCommTimeouts);
   }
}

/**
 *   Main class encapsulating platform dependent files handles and
 *   algorithms to work with serial port.
 *
 *   You can open serial port only once, after calling close any 
 *   nonstatic method will throw DeviceClosedException.
 *
 *   Note: Serial port enumerating is robust only on Windows, due
 *   other platform doesn't strictly bound serial port names.
 */
class SerialPort
{
   /**
    *   Creates new serial port instance.
    *
    *   Params:
    *   port =  Port name. On Posix, it should be reffer to device file
    *           like /dev/ttyS<N>. On Windows, port name should be like 
    *           COM<N> or any other.
    *
    *   Throws: InvalidParametersException, InvalidDeviceException
    *   
    */
   this(string port)
   {
      setup(port);
   }

   /**
    *   Creates new serial port instance.
    *
    *   Params:
    *   port =  Port name. On Posix, it should be reffer to device file
    *           like /dev/ttyS<N>. On Windows, port name should be like 
    *           COM<N> or any other.
    *   readTimeout  = Setups constant timeout on read operations.
    *   writeTimeout = Setups constant timeout on write operations. In posix is ignored.
    *
    *   Throws: InvalidParametersException, InvalidDeviceException
    */
   this(string port, Duration readTimeout, Duration writeTimeout)
   {
      readTimeoutConst = readTimeout;
      writeTimeoutConst = writeTimeout;
      this(port);
   }

   /**
    *   Creates new serial port instance.
    *
    *   Params:
    *   port =  Port name. On Posix, it should be reffer to device file
    *           like /dev/ttyS<N>. On Windows, port name should be like 
    *           COM<N> or any other.
    *   readTimeoutConst  = Setups constant timeout on read operations.
    *   writeTimeoutConst = Setups constant timeout on write operations. In posix is ignored.
    *   readTimeoutMult   = Setups timeout on read operations depending on buffer size.
    *   writeTimeoutMult  = Setups timeout on write operations depending on buffer size. 
    *                       In posix is ignored.
    *   
    *   Note: Total timeout is calculated as timeoutMult*buff.length + timeoutConst.
    *   Throws: InvalidParametersException, InvalidDeviceException
    */
   this(string port, Duration readTimeoutMult, Duration readTimeoutConst,
         Duration writeTimeoutMult, Duration writeTimeoutConst)
   {
      this.readTimeoutMult = readTimeoutMult;
      this.readTimeoutConst = readTimeoutConst;
      this.writeTimeoutMult = writeTimeoutMult;
      this.writeTimeoutConst = writeTimeoutConst;
      this(port);
   }

   ~this()
   {
      close();
   }

   /**
    *   Converts serial port to it port name. 
    *   Example: "ttyS0", "ttyS1", "COM1", "CNDA1".
    */
   override string toString()
   {
      return port;
   }

   /**
    *   Set the baud rate for this serial port. Speed values are usually 
    *   restricted to be 1200 * i ^ 2.
    *
    *   Note: that for Posix, the specification only mandates speeds up
    *   to 38400, excluding speeds such as 7200, 14400 and 28800.
    *   Most Posix systems have chosen to support at least higher speeds
    *   though.
    *
    *   Throws: SpeedUnsupportedException if speed is unsupported by current system.
    */
   SerialPort speed(BaudRate speed) @property
   {
      if (closed) throw new DeviceClosedException();

      version(Posix)
      {
         speed_t baud = convertPosixSpeed(speed);

         termios options;
         tcgetattr(handle, &options);
         cfsetospeed(&options, baud);
         tcsetattr(handle, TCSANOW, &options);
      }
      version(Windows)
      {
         DCB config;
         GetCommState(handle, &config);
         config.BaudRate = cast(DWORD)speed;
         if(!SetCommState(handle, &config))
         {
            throw new SpeedUnsupportedException(speed);
         }
      }

      return this;
   }

   /**
    *   Returns current port speed. Can return BR_UNKNONW baud rate
    *   if speed was changed not by speed property or wreid errors are occured.
    */
   BaudRate speed() @property
   {
      if (closed) throw new DeviceClosedException();

      version(Posix)
      {
         termios options;
         tcgetattr(handle, &options);
         speed_t baud = cfgetospeed(&options);
         return getBaudSpeed(cast(uint)baud);
      }
      version(Windows)
      {
         DCB config;
         GetCommState(handle, &config);
         return getBaudSpeed(cast(uint)config.BaudRate);
      }
   }

   /**
    *   Set the parity rate for this serial port.
    */
   SerialPort parity(Parity parity) @property
   {
      if (closed) throw new DeviceClosedException();

      version(Posix)
      {
         termios options;
         tcgetattr(handle, &options);
         switch (parity) {
            case Parity.none:
               options.c_cflag &= ~PARENB;
               break;
            case Parity.odd:
               options.c_cflag |= (PARENB | PARODD);
               break;
            case Parity.even:
               options.c_cflag &= ~PARODD;
               options.c_cflag |= PARENB;
               break;
            default:
               throw new ParityUnsupportedException(parity);
         }
         tcsetattr(handle, TCSANOW, &options);
      }
      version(Windows)
      {
         DCB config;
         GetCommState(handle, &config);
         switch (parity) {
            case Parity.none:
               config.Parity = NOPARITY;
               break;
            case Parity.odd:
               config.Parity = ODDPARITY;
               break;
            case Parity.even:
               config.Parity = EVENPARITY;
               break;
            default:
               throw new ParityUnsupportedException(parity);
         }

         if(!SetCommState(handle, &config))
         {
            throw new SpeedUnsupportedException(speed);
         }
      }

      return this;
   }

version(none) {
   /**
    *   Returns current port speed. Can return BR_UNKNONW baud rate
    *   if speed was changed not by speed property or wreid errors are occured.
    */
   Parity parity() @property
   {
      if (closed) throw new DeviceClosedException();

      version(Posix)
      {
         termios options;
         tcgetattr(handle, &options);
         speed_t baud = cfgetospeed(&options);
         return getBaudSpeed(cast(uint)baud);
      }
      version(Windows)
      {
         DCB config;
         GetCommState(handle, &config);
         return getBaudSpeed(cast(uint)config.BaudRate);
      }
   }
}


   /**
    *   Iterates over all bauds rate and tries to setup port with it.
    *   Returns: array of successfully setuped baud rates for current 
    *   serial port.
    */
   BaudRate[] getBaudRates()
   {
      if (closed) throw new DeviceClosedException();
      BaudRate currSpeed = speed;
      BaudRate[] ret; 
      foreach(baud; __traits(allMembers, BaudRate))
      {
         auto baudRate = mixin("BaudRate."~baud);
         if(baudRate != BaudRate.BR_UNKNOWN)
         {
            try
            {
               speed = baudRate;
               ret ~= baudRate;
            } 
            catch(SpeedUnsupportedException e)
            {

            }
         }
      }

      speed = currSpeed;
      return ret;
   }

   /**
    *   Tries to enumerate all serial ports. While this usually works on
    *   Windows, it's more problematic on other OS. Posix provides no way
    *   to list serial ports, and the only option is searching through
    *   "/dev".
    *
    *   Because there's no naming standard for the device files, this method
    *   must be ported for each OS. This method is also unreliable because
    *   the user could have created invalid device files, or deleted them.
    *
    *   Returns:
    *   A string array of all the serial ports that could be found, in
    *   alphabetical order. Every string is formatted as a valid argument
    *   to the constructor, but the port may not be accessible.
    */
   static string[] ports()
   {
      string[] ports;
      version(Windows)
      {
         // try to open COM1..255
         immutable pre = `\\.\COM`;
         for(int i = 1; i <= 255; ++i)
         {
            HANDLE port = CreateFileA(text(pre, i).toStringz, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
            if(port != INVALID_HANDLE_VALUE)
            {
               ports ~= text("COM", i);
               CloseHandle(port);
            }
         }
      }
      version(Posix)
      {
         bool comFilter(DirEntry entry)
         {
            bool isInRange(T, U)(T val, U lower, U upper)
            {
               auto cval = val.to!U;
               return cval >= lower && cval <= upper;
            }

            version(linux)
            {
               return (entry.name.countUntil("ttyUSB") == 5
                     || entry.name.countUntil("ttyS") == 5);
            }
            version(darwin)
            {
               return entry.name.countUntil("cu") == 5;
            }
            version(FreeBSD)
            {
               return (entry.name.countUntil("cuaa") == 5
                     || entry.name.countUntil("cuad") == 5);
            }
            version(openbsd)
            {
               return entry.name.countUntil("tty") == 5;
            }
            version(solaris)
            {
               return entry.name.countUntil("tty") == 5
                  && isInRange(entry.name[$-1], 'a', 'z');
            }
         }

         auto portFiles = filter!(comFilter)(dirEntries("/dev",SpanMode.shallow));
         foreach(entry; portFiles)
         {
            ports ~= entry.name;
         }
      }
      return ports;
   }

   /**
    *   Closing underlying serial port. You shouldn't use port after
    *   it closing.
    */
   void close()
   {
      version(Windows)
      {
         if(handle !is null)
         {
            CloseHandle(handle);
            handle = null;
         }
      }
      version(Posix)
      {
         if(handle != -1)
         {
            posixClose(handle);
            handle = -1;
         }
      }
   }

   /**
    *   Returns true if serial port was closed.
    */
   bool closed() @property
   {
      version(Windows)
         return handle is null;
      version(Posix)
         return handle == -1;
   }

   /**
    *   Writes down array of bytes to serial port.
    *
    *   Throws: TimeoutException (Windows only)
    */
   void write(const(void[]) arr)
   {
      if (closed) throw new DeviceClosedException();

      version(Windows)
      {
         uint written;
         if(!WriteFile(handle, arr.ptr, 
                  cast(uint)arr.length, &written, null))
            throw new DeviceWriteException(port);
         if(arr.length != written)
            throw new TimeoutException(port, written);
      }
      version(Posix)
      {
         size_t totalWritten;
         while(totalWritten < arr.length)
         {
            ssize_t result = posixWrite(handle, arr[totalWritten..$].ptr, arr.length - totalWritten);
            if(result < 0)
               throw new DeviceWriteException(port);
            totalWritten += cast(size_t)result;
         }
      }
   } 

   /**
    *   Fills up provided array with bytes from com port.
    *   Returns: actual number of readed bytes.
    *   Throws: DeviceReadException, TimeoutException
    */
   size_t read(void[] arr)
   {
      if (closed) throw new DeviceClosedException();

      version(Windows)
      {
         uint readed;
         if(!ReadFile(handle, arr.ptr, cast(uint)arr.length, &readed, null))
            throw new DeviceReadException(port);
         if(arr.length != readed) 
            throw new TimeoutException(port, cast(size_t)readed);
         return cast(size_t)readed;
      }
      version(Posix)
      {
         fd_set selectSet;
         FD_ZERO(&selectSet);
         FD_SET(handle, &selectSet);

         timeval timeout;
         timeout.tv_sec = cast(int)(arr.length * readTimeoutMult.total!"seconds" + readTimeoutConst.total!"seconds");
         timeout.tv_usec = cast(int)(arr.length * readTimeoutMult.fracSec.msecs + readTimeoutConst.fracSec.msecs);

         auto rv = select(handle + 1, &selectSet, null, null, &timeout);
         if(rv == -1)
         {
            throw new DeviceReadException(port);
         } else if(rv == 0)
         {
            throw new TimeoutException(port, 0);
         }

         ssize_t result = posixRead(handle, arr.ptr, arr.length);
         if(result < 0) 
         {
            throw new DeviceReadException(port);
         }
         return cast(size_t)result;
      }
   }

   protected
   {
      version(Windows)
      {
         private void setup(string port)
         {
            this.port = port;
            handle = CreateFileA((`\\.\` ~ port).toStringz, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
            if(handle is INVALID_HANDLE_VALUE)
            {
               throw new InvalidDeviceException(port);
            }

            DCB config;
            GetCommState(handle, &config);
            config.BaudRate = 9600;
            config.ByteSize = 8;
            config.Parity = NOPARITY;
            config.StopBits = ONESTOPBIT;
            config.fBinary = 1;
            config.fParity = 1;

            COMMTIMEOUTS timeouts;
            timeouts.ReadIntervalTimeout         = 0;
            timeouts.ReadTotalTimeoutMultiplier  = cast(DWORD)readTimeoutMult.total!"msecs";
            timeouts.ReadTotalTimeoutConstant    = cast(DWORD)readTimeoutConst.total!"msecs";
            timeouts.WriteTotalTimeoutMultiplier = cast(DWORD)writeTimeoutMult.total!"msecs";
            timeouts.WriteTotalTimeoutConstant   = cast(DWORD)writeTimeoutConst.total!"msecs";
            import std.stdio; writeln(timeouts);
            if (SetCommTimeouts(handle, &timeouts) == 0) 
            {
               throw new InvalidParametersException(port);
            }

            if(!SetCommState(handle, &config))
            {
               throw new InvalidParametersException(port);
            }
         }
      }

      version(Posix)
      {
         private static __gshared speed_t[BaudRate] posixBRTable;
         shared static this()
         {
            posixBRTable = [
               BaudRate.BR_110 : B110,
               BaudRate.BR_300 : B300,
               BaudRate.BR_600 : B600,
               BaudRate.BR_1200 : B1200,
               BaudRate.BR_2400 : B2400,
               BaudRate.BR_4800 : B4800,
               BaudRate.BR_9600 : B9600,
               BaudRate.BR_38400 : B38400,
               BaudRate.BR_57600 : B57600,
               BaudRate.BR_115200 : B115200
            ];
         }

         speed_t convertPosixSpeed(BaudRate baud)
         {
            if(baud in posixBRTable) return posixBRTable[baud];
            throw new SpeedUnsupportedException(baud);
         }

         void setup(string file)
         {
            if(file.length == 0) throw new InvalidDeviceException(file);

            port = file;

            handle = open(file.toStringz(), O_RDWR | O_NOCTTY | O_NONBLOCK);
            if(handle == -1) 
            {
               throw new InvalidDeviceException(file);
            }
            if(fcntl(handle, F_SETFL, 0) == -1)  // disable O_NONBLOCK
            {   
               throw new InvalidDeviceException(file);
            }

            termios options;
            if(tcgetattr(handle, &options) == -1) 
            {
               throw new InvalidDeviceException(file);
            }
            cfsetispeed(&options, B0); // same as output baud rate
            cfsetospeed(&options, B9600);
            makeRaw(options); // disable echo and special characters
            tcsetattr(handle, TCSANOW, &options);
         }

         void makeRaw (ref termios options)
         {
            options.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | 
                  INLCR | IGNCR | ICRNL | IXON);
            options.c_oflag &= ~OPOST;
            options.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
            options.c_cflag &= ~(CSIZE | PARENB);
            options.c_cflag |= CS8;
         }
      }

      private static __gshared BaudRate[uint] baudRatetoUint;
      shared static this() 
      {
         version(Windows)
         {
            baudRatetoUint = [
               110 : BaudRate.BR_110,
                   300 : BaudRate.BR_300,
                   600 : BaudRate.BR_600,
                   1200 : BaudRate.BR_1200,
                   2400 : BaudRate.BR_2400,
                   4800 : BaudRate.BR_4800,
                   9600 : BaudRate.BR_9600,
                   38_400 : BaudRate.BR_38400,
                   57_600 : BaudRate.BR_57600,
                   115_200 : BaudRate.BR_115200,
            ];
         }
         version(linux)
         {
            baudRatetoUint = [
               B110 : BaudRate.BR_110,
                    B300 : BaudRate.BR_300,
                    B600 : BaudRate.BR_600,
                    B1200 : BaudRate.BR_1200,
                    B2400 : BaudRate.BR_2400,
                    B4800 : BaudRate.BR_4800,
                    B9600 : BaudRate.BR_9600,
                    B38400 : BaudRate.BR_38400,
                    B57600 : BaudRate.BR_57600,
                    B115200 : BaudRate.BR_115200,
            ];
         }
      }

      static BaudRate getBaudSpeed(uint value)
      {
         if(value in baudRatetoUint) return baudRatetoUint[value];
         return BaudRate.BR_UNKNOWN;
      }
   }

   private
   {
      /// Port name
      string port;
      /// Port handle
      version(Posix)
         int handle = -1;
      version(Windows)
         HANDLE handle = null;

      Duration readTimeoutMult;
      Duration readTimeoutConst;
      Duration writeTimeoutMult;
      Duration writeTimeoutConst;
   }   
}
