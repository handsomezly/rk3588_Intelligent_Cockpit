from queue import Queue
from rknnlite.api import RKNNLite
from concurrent.futures import ThreadPoolExecutor, as_completed


def _core_mask(id):
    if id == 0:
        return RKNNLite.NPU_CORE_0
    if id == 1:
        return RKNNLite.NPU_CORE_1
    if id == 2:
        return RKNNLite.NPU_CORE_2
    if id == -1:
        return RKNNLite.NPU_CORE_0_1_2
    return None


def initRKNN(rknnModel="./rknnModel/best.rknn", id=-1):
    rknn_lite = RKNNLite()
    ret = rknn_lite.load_rknn(rknnModel)
    if ret != 0:
        print("Load RKNN rknnModel failed")
        exit(ret)
    mask = _core_mask(id)
    if mask is None:
        ret = rknn_lite.init_runtime()
    else:
        ret = rknn_lite.init_runtime(core_mask=mask)
    if ret != 0:
        print("Init runtime environment failed")
        exit(ret)
    print(rknnModel, "\t\tdone")
    return rknn_lite


def initRKNNs(face_model, eye_model=None, TPEs=1):
    """Build TPE worker contexts. Each worker holds (face_rknn, eye_rknn_or_None).

    Plan-mandated invariant: per worker, face and eye contexts must share the
    same NPU core_mask so the two inferences in one frame don't migrate cores.
    """
    pool = []
    for i in range(TPEs):
        core_id = i % 3
        face = initRKNN(face_model, core_id)
        eye = initRKNN(eye_model, core_id) if eye_model else None
        pool.append((face, eye))
    return pool


class rknnPoolExecutor:
    """Round-robin TPE pool. Worker callable signature: func(face, eye_or_None, frame)."""

    def __init__(self, face_model, eye_model=None, TPEs=3, func=None,
                 rknnModel=None):
        # rknnModel kept as legacy alias for the old single-model call site.
        if face_model is None and rknnModel is not None:
            face_model = rknnModel
        if face_model is None:
            raise ValueError("face_model is required")
        if func is None:
            raise ValueError("func is required")

        self.TPEs = TPEs
        self.queue = Queue()
        self.rknnPool = initRKNNs(face_model, eye_model, TPEs)
        self.pool = ThreadPoolExecutor(max_workers=TPEs)
        self.func = func
        self.num = 0

    def put(self, frame):
        face, eye = self.rknnPool[self.num % self.TPEs]
        self.queue.put(self.pool.submit(self.func, face, eye, frame))
        self.num += 1

    def get(self):
        if self.queue.empty():
            return None, False
        temp = []
        temp.append(self.queue.get())
        for fut in as_completed(temp):
            return fut.result(), True

    def drain(self):
        """Wait for and discard every queued inference result."""
        drained = 0
        while not self.queue.empty():
            _, ok = self.get()
            if ok:
                drained += 1
        return drained

    def release(self):
        self.pool.shutdown()
        for face, eye in self.rknnPool:
            face.release()
            if eye is not None:
                eye.release()

    def get_num(self):
        return self.num
