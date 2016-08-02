import ClientServer::*;
import UnionGenerated::*;
import StructGenerated::*;
import TxRx::*;
import FIFOF::*;
import Ethernet::*;
import MatchTable::*;
import Vector::*;
import Pipe::*;
import GetPut::*;
import Utils::*;
import DefaultValue::*;

// ====== IPV4_MATCH ======

typedef struct {
  Bit#(4) padding;
  Bit#(32) ipv4$srcAddr;
} Ipv4MatchReqT deriving (Bits, Eq, FShow);
typedef enum {
  DEFAULT_IPV4_MATCH,
  NOP,
  SET_EGRESS_PORT
} Ipv4MatchActionT deriving (Bits, Eq, FShow);
typedef struct {
  Ipv4MatchActionT _action;
  Bit#(8) runtime_egress_port;
} Ipv4MatchRspT deriving (Bits, Eq, FShow);
`ifndef SVDPI
import "BDPI" function ActionValue#(Bit#(10)) matchtable_read_ipv4_match(Bit#(36) msgtype);
import "BDPI" function Action matchtable_write_ipv4_match(Bit#(36) msgtype, Bit#(10) data);
`endif
instance MatchTableSim#(1, 36, 10);
  function ActionValue#(Bit#(10)) matchtable_read(Bit#(1) id, Bit#(36) key);
    actionvalue
      let v <- matchtable_read_ipv4_match(key);
      return v;
    endactionvalue
  endfunction

  function Action matchtable_write(Bit#(1) id, Bit#(36) key, Bit#(10) data);
    action
      matchtable_write_ipv4_match(key, data);
    endaction
  endfunction

endinstance
interface Ipv4Match;
  interface Server #(MetadataRequest, Ipv4MatchResponse) prev_control_state_0;
  interface Client #(BBRequest, BBResponse) next_control_state_0;
  interface Client #(BBRequest, BBResponse) next_control_state_1;
endinterface
(* synthesize *)
module mkIpv4Match  (Ipv4Match);
  RX #(MetadataRequest) rx_metadata <- mkRX;
  let rx_info_metadata = rx_metadata.u;
  TX #(Ipv4MatchResponse) tx_metadata <- mkTX;
  let tx_info_metadata = tx_metadata.u;
  Vector#(2, FIFOF#(BBRequest)) bbReqFifo <- replicateM(mkFIFOF);
  Vector#(2, FIFOF#(BBResponse)) bbRspFifo <- replicateM(mkFIFOF);
  FIFOF#(PacketInstance) packet_ff <- mkFIFOF;
  MatchTable#(1, 256, SizeOf#(Ipv4MatchReqT), SizeOf#(Ipv4MatchRspT)) matchTable <- mkMatchTable("ipv4_match.dat");
  Vector#(2, Bool) readyBits = map(fifoNotEmpty, bbRspFifo);
  Bool interruptStatus = False;
  Bit#(2) readyChannel = -1;
  for (Integer i=1; i>=0; i=i-1) begin
      if (readyBits[i]) begin
          interruptStatus = True;
          readyChannel = fromInteger(i);
      end
  end

  Vector#(2, FIFOF#(MetadataT)) metadata_ff <- replicateM(mkFIFOF);
  rule rl_handle_request;
    let data = rx_info_metadata.first;
    rx_info_metadata.deq;
    let meta = data.meta;
    let pkt = data.pkt;
    let ipv4$srcAddr = fromMaybe(?, meta.ipv4$srcAddr);
    Ipv4MatchReqT req = Ipv4MatchReqT {padding: 0, ipv4$srcAddr: ipv4$srcAddr};
    matchTable.lookupPort.request.put(pack(req));
    packet_ff.enq(pkt);
    metadata_ff[0].enq(meta);
  endrule

  rule rl_handle_execute;
    let rsp <- matchTable.lookupPort.response.get;
    let pkt <- toGet(packet_ff).get;
    let meta <- toGet(metadata_ff[0]).get;
    if (rsp matches tagged Valid .data) begin
      Ipv4MatchRspT resp = unpack(data);
      case (resp._action) matches
        NOP: begin
          BBRequest req = tagged NopReqT {pkt: pkt};
          bbReqFifo[0].enq(req); //FIXME: replace with RXTX.
        end
        SET_EGRESS_PORT: begin
          BBRequest req = tagged SetEgressPortReqT {pkt: pkt, runtime_egress_port_8: resp.runtime_egress_port};
          bbReqFifo[1].enq(req); //FIXME: replace with RXTX.
        end
      endcase
      // forward metadata to next stage.
      metadata_ff[1].enq(meta);
    end
  endrule

  rule rl_handle_response if (interruptStatus);
    let v <- toGet(bbRspFifo[readyChannel]).get;
    let meta <- toGet(metadata_ff[1]).get;
    case (v) matches
      tagged NopRspT {pkt: .pkt}: begin
        Ipv4MatchResponse rsp = tagged Ipv4MatchNopRspT {pkt: pkt, meta: meta};
        tx_info_metadata.enq(rsp);
      end
      tagged SetEgressPortRspT {pkt: .pkt, ing_metadata$egress_port: .ing_metadata$egress_port}: begin
        meta.ing_metadata$egress_port = tagged Valid ing_metadata$egress_port;
        Ipv4MatchResponse rsp = tagged Ipv4MatchSetEgressPortRspT {pkt: pkt, meta: meta};
        tx_info_metadata.enq(rsp);
      end
    endcase
  endrule

  interface prev_control_state_0 = toServer(rx_metadata.e, tx_metadata.e);
  interface next_control_state_0 = toClient(bbReqFifo[0], bbRspFifo[0]);
  interface next_control_state_1 = toClient(bbReqFifo[1], bbRspFifo[1]);
endmodule
