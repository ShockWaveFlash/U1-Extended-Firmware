# Code to implement asynchronous logging from a background thread
#
# Copyright (C) 2016-2019  Kevin O'Connor <kevin@koconnor.net>
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging
import logging.handlers
import queue
import threading
import time


FILE_SIZE  = 10 * 1024 * 1024   # 10 MiB
FILE_COUNT = 15                 # 15 files

# Custom formatter to add timestamp with milliseconds
class MillisecondFormatter(logging.Formatter):
    def formatTime(self, record, datefmt=None):
        ct = self.converter(record.created)
        if datefmt:
            s = time.strftime(datefmt, ct)
        else:
            s = time.strftime("%m-%d %H:%M:%S", ct)
        return "%s.%03d" % (s, (record.msecs % 1000))

# Class to forward all messages through a queue to a background thread
class QueueHandler(logging.Handler):
    def __init__(self, queue):
        logging.Handler.__init__(self)
        self.queue = queue

    def emit(self, record):
        try:
            self.format(record)
            record.msg = record.message
            record.args = None
            record.exc_info = None
            self.queue.put_nowait(record)
        except Exception:
            self.handleError(record)


# Class to poll a queue in a background thread and log each message
class QueueListener(logging.handlers.RotatingFileHandler):
    # Snapmaker: groessenbasierte Rotation (Flash-Speicher im Geraet).
    # rotate_log_at_restart wird fuer Kalicos Aufrufform akzeptiert; die
    # Rotation beim Start loest der Aufrufer per doRollover() aus.
    def __init__(self, filename, maxBytes=FILE_SIZE, backupCount=FILE_COUNT,
                 rotate_log_at_restart=False):
        logging.handlers.RotatingFileHandler.__init__(
            self, filename, maxBytes=maxBytes, backupCount=backupCount)
        # Add formatter with milliseconds
        formatter = MillisecondFormatter("%(asctime)s:%(message)s")
        self.setFormatter(formatter)
        self.bg_queue = queue.Queue()
        self.bg_thread = threading.Thread(target=self._bg_thread)
        self.bg_thread.start()
        self.rollover_info = {}

    def _bg_thread(self):
        while True:
            record = self.bg_queue.get(True)
            if record is None:
                break
            self.handle(record)

    def stop(self):
        self.bg_queue.put_nowait(None)
        self.bg_thread.join()

    def set_rollover_info(self, name, info):
        if info is None:
            self.rollover_info.pop(name, None)
            return
        self.rollover_info[name] = info

    def clear_rollover_info(self):
        self.rollover_info.clear()

    def doRollover(self):
        logging.handlers.RotatingFileHandler.doRollover(self)
        lines = [
            self.rollover_info[name] for name in sorted(self.rollover_info)
        ]
        lines.append(
            "=============== Log rollover at %s ==============="
            % (time.asctime(),)
        )
        self.emit(
            logging.makeLogRecord(
                {"msg": "\n".join(lines), "level": logging.INFO}
            )
        )


MainQueueHandler = None


def setup_bg_logging(filename, debuglevel, maxBytes=FILE_SIZE,
                     rotate_log_at_restart=False):
    global MainQueueHandler
    ql = QueueListener(
        filename=filename, maxBytes=maxBytes,
        rotate_log_at_restart=rotate_log_at_restart
    )
    MainQueueHandler = QueueHandler(ql.bg_queue)
    root = logging.getLogger()
    root.addHandler(MainQueueHandler)
    root.setLevel(debuglevel)
    return ql


def clear_bg_logging():
    global MainQueueHandler
    if MainQueueHandler is not None:
        root = logging.getLogger()
        root.removeHandler(MainQueueHandler)
        root.setLevel(logging.WARNING)
        MainQueueHandler = None
