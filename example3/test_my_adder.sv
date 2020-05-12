 
// To verify that the adder adds, we also need to check that it 
// does not add when rstn is 0, and hence rstn should also be 
// randomized along with a and b.
class Packet;
  rand bit     rstn;
  rand bit[7:0] a;
  rand bit[7:0] b;
  bit [7:0]   sum;
  bit       carry;
 
  // Print contents of the data packet
  function void print(string tag="");
    $display ("T=%0t %s a=0x%0h b=0x%0h sum=0x%0h carry=0x%0h", $time, tag, a, b, sum, carry);
  endfunction
 
  // This is a utility function to allow copying contents in 
  // one Packet variable to another.
  function void copy(Packet tmp);
    this.a = tmp.a;
    this.b = tmp.b;
    this.rstn = tmp.rstn;
    this.sum = tmp.sum;
    this.carry = tmp.carry;
  endfunction
endclass


class driver;
  virtual adder_if m_adder_vif;
  virtual clk_if  m_clk_vif;
  event drv_done;
  mailbox drv_mbx;

  task run();
    $display ("T=%0t [Driver] starting ...", $time);

    // Try to get a new transaction every time and then assign
    // packet contents to the interface. But do this only if the
    // design is ready to accept new transactions
    forever begin
      Packet item;

      $display ("T=%0t [Driver] waiting for item ...", $time);
      drv_mbx.get(item);
      @ (posedge m_clk_vif.tb_clk);
    item.print("Driver");
      m_adder_vif.rstn <= item.rstn;
      m_adder_vif.a <= item.a;
      m_adder_vif.b <= item.b;
      ->drv_done;
    end
  endtask
endclass

// The monitor has a virtual interface handle with which it can monitor
// the events happening on the interface. It sees new transactions and then
// captures information into a packet and sends it to the scoreboard
// using another mailbox.
class monitor;
  virtual adder_if   m_adder_vif;
  virtual clk_if   m_clk_vif;

  mailbox scb_mbx;     // Mailbox connected to scoreboard

  task run();
    $display ("T=%0t [Monitor] starting ...", $time);

    // Check forever at every clock edge to see if there is a
    // valid transaction and if yes, capture info into a class
    // object and send it to the scoreboard when the transaction
    // is over.
    forever begin
    Packet m_pkt = new();
      @(posedge m_clk_vif.tb_clk);
      #1;
        m_pkt.a   = m_adder_vif.a;
        m_pkt.b   = m_adder_vif.b;
        m_pkt.rstn   = m_adder_vif.rstn;
        m_pkt.sum   = m_adder_vif.sum;
        m_pkt.carry = m_adder_vif.carry;
        m_pkt.print("Monitor");
      scb_mbx.put(m_pkt);
    end
  endtask
endclass

// The scoreboard is responsible to check data integrity. Since the design
// simple adds inputs to give sum and carry, scoreboard helps to check if the
// output has changed for given set of inputs based on expected logic
class scoreboard;
  mailbox scb_mbx;

  task run();
    forever begin
      Packet item, ref_item;
      scb_mbx.get(item);
      item.print("Scoreboard");

      // Copy contents from received packet into a new packet so
      // just to get a and b.
      ref_item = new();
      ref_item.copy(item);

      // Let us calculate the expected values in carry and sum
      if (ref_item.rstn)
        {ref_item.carry, ref_item.sum} = ref_item.a + ref_item.b;
      else
      {ref_item.carry, ref_item.sum} = 0;

      // Now, carry and sum outputs in the reference variable can be compared
      // with those in the received packet
      if (ref_item.carry != item.carry) begin
        $display("[%0t] Scoreboard Error! Carry mismatch ref_item=0x%0h item=0x%0h", $time, ref_item.carry, item.carry);
      end else begin
        $display("[%0t] Scoreboard Pass! Carry match ref_item=0x%0h item=0x%0h", $time, ref_item.carry, item.carry);
      end

      if (ref_item.sum != item.sum) begin
        $display("[%0t] Scoreboard Error! Sum mismatch ref_item=0x%0h item=0x%0h", $time, ref_item.sum, item.sum);
      end else begin
        $display("[%0t] Scoreboard Pass! Sum match ref_item=0x%0h item=0x%0h", $time, ref_item.sum, item.sum);
      end
    end
  endtask
endclass

// Sometimes we simply need to generate N random transactions to random
// locations so a generator would be useful to do just that. In this case
// loop determines how many transactions need to be sent
class generator;
  int   loop = 10;
  event drv_done;
  mailbox drv_mbx;

  task run();
    for (int i = 0; i < loop; i++) begin
      Packet item = new;
      item.randomize();
      $display ("T=%0t [Generator] Loop:%0d/%0d create next item", $time, i+1, loop);
      drv_mbx.put(item);
      $display ("T=%0t [Generator] Wait for driver to be done", $time);
      @(drv_done);
    end
  endtask
endclass


// Lets say that the environment class was already there, and generator is
// a new component that needs to be included in the ENV.
class env;
  generator     g0;       // Generate transactions
  driver       d0;       // Driver to design
  monitor       m0;       // Monitor from design
  scoreboard     s0;       // Scoreboard connected to monitor
  mailbox       scb_mbx;     // Top level mailbox for SCB <-> MON
  virtual adder_if   m_adder_vif;   // Virtual interface handle
  virtual clk_if   m_clk_vif;     // TB clk

  event drv_done;
  mailbox drv_mbx;

  function new();
    d0 = new;
    m0 = new;
    s0 = new;
    scb_mbx = new();
    g0 = new;
    drv_mbx = new;
  endfunction

  virtual task run();
    // Connect virtual interface handles
    d0.m_adder_vif = m_adder_vif;
    m0.m_adder_vif = m_adder_vif;
    d0.m_clk_vif = m_clk_vif;
    m0.m_clk_vif = m_clk_vif;

    // Connect mailboxes between each component
    d0.drv_mbx = drv_mbx;
    g0.drv_mbx = drv_mbx;

    m0.scb_mbx = scb_mbx;
    s0.scb_mbx = scb_mbx;

    // Connect event handles
    d0.drv_done = drv_done;
    g0.drv_done = drv_done;

    // Start all components - a fork join_any is used because
    // the stimulus is generated by the generator and we want the
    // simulation to exit only when the generator has finished
    // creating all transactions. Until then all other components
    // have to run in the background.
    fork
      s0.run();
    d0.run();
      m0.run();
        g0.run();
    join_any
  endtask
endclass

// The test can instantiate any environment. In this test, we are using
// an environment without the generator and hence the stimulus should be
// written in the test.
class test;
  env e0;
  mailbox drv_mbx;

  function new();
    drv_mbx = new();
    e0 = new();
  endfunction

  virtual task run();
    e0.d0.drv_mbx = drv_mbx;
    e0.run();
  endtask
endclass


// Adder interface contains all signals that the adder requires
// to operate
interface adder_if();
  logic     rstn;
  logic [7:0]   a;
  logic [7:0]   b;
  logic [7:0]   sum;
  logic     carry;
endinterface

// Although an adder does not have a clock, let us create a mock clock
// used in the testbench to synchronize when value is driven and when
// value is sampled. Typically combinational logic is used between
// sequential elements like FF in a real circuit. So, let us assume
// that inputs to the adder is provided at some posedge clock. But because
// the design does not have clock in its input, we will keep this clock
// in a separate interface that is available only to testbench components
interface clk_if();
  logic tb_clk;

  initial tb_clk <= 0;

  always #10 tb_clk = ~tb_clk;
endinterface

module tb;
  bit tb_clk;

  clk_if   m_clk_if   ();
  adder_if   m_adder_if  ();
  my_adder   u0       (m_adder_if);

  initial begin
    test t0;

    t0 = new;
    t0.e0.m_adder_vif = m_adder_if;
    t0.e0.m_clk_vif = m_clk_if;
    t0.run();

    // Once the main stimulus is over, wait for some time
    // until all transactions are finished and then end
    // simulation. Note that $finish is required because
    // there are components that are running forever in
    // the background like clk, monitor, driver, etc
    #50 $finish;
  end
endmodule
