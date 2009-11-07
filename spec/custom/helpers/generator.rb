# TODO: document TestGenerator
module Rubinius
  class TestGenerator
    class Label
      attr_reader :ip

      def initialize(gen)
        @generator = gen
        @ip = nil
        @used = false
      end

      attr_reader :used
      alias_method :used?, :used

      def used!
        @used = true
      end

      def inspect
        self.to_sym.inspect
      end

      def to_sym
        raise "Unset label!" unless @ip
        :"label_#{@ip}"
      end

      def set!
        @ip = @generator.new_label_id
        @generator.set_label self.to_sym
      end

      def ==(lbl)
        raise "Unset label!" unless @ip
        return self.to_sym == lbl if Symbol === lbl
        @ip == lbl.ip
      end
    end

    # TestGenerator methods

    def self.define_opcode_method(name)
      class_eval <<-CODE
        def #{name}(*args)
          add :#{name}, *args
        end
      CODE
    end

    excluded_opcodes = [:class, :goto, :set_label, :cast_array, :setup_unwind]

    Rubinius::InstructionSet.opcodes.each do |opcode|
      next if excluded_opcodes.include? opcode.name
      define_opcode_method opcode.name
    end

    [:add_literal,
     :pop_modifiers,
     :push,
     :push_literal_at,
     :push_modifiers,
     :send,
     :send_super,
     :send_with_block,
     :send_with_splat,
     :swap].each do |name|
      define_opcode_method name
    end

    def git(lbl)
      lbl.used!
      add :goto_if_true, lbl
    end

    def gif(lbl)
      lbl.used!
      add :goto_if_false, lbl
    end

    # The :g accessor is provided to make the code in the
    # utility methods below clearer
    attr_reader   :g
    attr_accessor :stream, :ip, :redo, :break, :next, :retry,
                  :name, :file, :line, :required_args, :total_args, :splat_index,
                  :local_count, :local_names, :primitive, :for_block


    def initialize
      @stream = []
      @ip     = 0
      @lbl    = 0
      @slot   = 0
      @g      = self
      @state = []
    end

    def state
      @state.last
    end

    # TODO: put TestGenerator under Rubinius
    def push_state(scope)
      @state << Rubinius::AST::State.new(scope)
    end

    def pop_state
      @state.pop
    end
    def run(node)
      node.bytecode(self)
    end

    def convert_to_ary(ary)
      ary.map do |item|
        if item.respond_to? :to_ary
          convert_to_ary item.to_ary
        else
          item
        end
      end
    end

    def to_a
      convert_to_ary [:test_generator, @stream]
    end

    def pretty_inspect
      to_a.pretty_inspect
    end

    def inspect
      to_a.inspect
    end

    def add(*args)
      @last = args
      @stream << args
      @ip += 1
    end

    def new_slot
      @ip
    end

    def new_label
      Label.new self
    end

    def new_label_id
      @lbl += 1
      @lbl
    end

    def dup
      add :dup
    end

    def set_line(line)
      @line = line
    end

    def set_label(lbl)
      @stream << [:set_label, lbl.to_sym]
    end

    def close
    end

    def ==(tg)
      tg.class == self.class && tg.stream == @stream
    end

    # Hack to provide expected semantics
    def ===(other)
      equal? other
    end

    def find_literal(lit)
      lit
    end

    def goto(x)
      raise "Bad goto: #{x.inspect} on #{caller.first}" unless Label === x
      x.used!
      add :goto, x
    end

    def setup_unwind(label, *)
      add :setup_unwind, label
    end

    def send_primitive(name)
      @primitive = name
    end

    def push_unique_literal(lit)
      push_literal lit
    end

    def push_generator(desc)
      push_literal desc
    end

    def push_literal_desc(name = nil)
      desc = description name do |d|
        yield d
      end

      g.push_literal desc
    end

    def description(name=nil)
      desc = Compiler::MethodDescription.new TestGenerator, 0
      desc.name = name if name

      yield desc.generator

      desc
    end

    def block_description
      iter = description :__block__ do |d|
        yield d
      end
      iter.required = -1

      g.create_block iter

      iter
    end

    def splatted_array(n=1)
      bottom = g.new_label

      if block_given?
        yield
      else
        g.push 1
      end
      g.make_array n

      g.cast_array
      g.dup
      g.send :size, 0
      g.push 1
      g.send :>, 1
      g.git bottom

      g.push 0
      g.send :at, 1

      bottom.set!
    end

    def in_block_send(name, type, required=nil, call_count=0, vis=true)
      iter = block_description do |d|
        count = nil

        case type
        when :none
          required = -1
        when :empty
          required = 0
        when :blank
          required = -1
          count = 0
        when :single
          required = 1
          d.cast_for_single_block_arg
          d.set_local 0
        when :splat
          required = -1
          d.cast_for_splat_block_arg
          d.cast_array
          d.cast_array
          d.set_local 0
        when :rest
          count = required.abs - 1
        when :multi
          count = required.abs
        end

        if count
          d.cast_for_multi_block_arg
          d.cast_array

          (0...count).each do |n|
            d.shift_array
            d.set_local n
            d.pop
          end
        end

        if type == :rest
          d.set_local count
        end

        if type != :none and type != :empty and type != 0
          d.pop
        end

        d.push_modifiers
        d.new_label.set!

        yield d

        d.pop_modifiers
        d.ret
      end
      iter.required = required

      g.send_with_block name, call_count, vis
    end

    def in_class(name)
      case name
      when Symbol then
        g.push_const :Rubinius
        g.push_literal name
        g.push :nil

        g.push_scope
        g.send :open_class, 3
      when String then
        g.push_const :Rubinius

        levels = name.split(/::/).map { |s| s.to_sym }
        klass = levels.pop

        g.push_literal klass
        g.push :nil

        levels.each do |level|
          g.push_const level
        end

        g.send :open_class_under, 3
      end

      return unless block_given?

      g.dup
      g.push_const :Rubinius
      g.swap
      g.push_literal :__class_init__
      g.swap
      g.push_literal_desc name do |d|
        d.push_self
        d.add_scope

        yield d

        d.ret
      end
      g.swap
      g.push_scope
      g.swap
      g.send :attach_method, 4
      g.pop
      g.send :__class_init__, 0
    end

    def in_method(name, singleton=false)
      if singleton
        g.send :metaclass, 0
      else
        g.push_const :Rubinius
      end

      g.push_literal name
      g.push_literal_desc name do |d|
        yield d
        d.ret
      end

      g.push_scope

      if singleton then
        g.send :attach_method, 3
      else
        g.push_variables
        g.send :method_visibility, 0
        g.send :add_defn_method, 4
      end
    end

    def in_module(name)
      case name
      when Symbol then
        g.push_const :Rubinius
        g.push_literal name
        g.push_scope
        g.send :open_module, 2
      when String then
        levels = name.split(/::/).map { |s| s.to_sym }
        klass = levels.pop

        g.push_const :Rubinius
        g.push_literal klass

        levels.each do |level|
          g.push_const level
        end

        g.send :open_module_under, 2
      end

      return unless block_given?

      g.dup
      g.push_const :Rubinius
      g.swap
      g.push_literal :__module_init__
      g.swap
      g.push_literal_desc do |d|
        d.push_self
        d.add_scope

        yield d

        d.ret
      end
      g.swap
      g.push_scope
      g.swap
      g.send :attach_method, 4
      g.pop
      g.send :__module_init__, 0
    end

    def in_rescue(*klasses)
      jump_retry   = g.new_label
      jump_else    = g.new_label
      jump_last    = g.new_label

      has_ensure = klasses.delete :ensure
      saved_exception_index = klasses.detect { |a| a.instance_of?(Fixnum) }
      if saved_exception_index
        klasses.delete saved_exception_index
      else
        saved_exception_index = 0
      end

      if has_ensure
        ensure_good = g.new_label
        ensure_bad = g.new_label

        g.setup_unwind ensure_bad

        jump_top = g.new_label
        jump_top.set!
      end

      g.push_modifiers
      g.push_exception

      jump_retry.set!

      exc_lbl = g.new_label
      g.setup_unwind exc_lbl

      g.new_label.set!

      yield :body

      g.pop_unwind
      g.goto jump_else

      exc_lbl.set!

      klasses.flatten.each do |klass|
        jump_body = self.new_label
        jump_next = self.new_label

        self.push_const klass
        self.push_exception
        self.send :===, 1
        self.git jump_body

        self.goto jump_next

        jump_body.set!

        yield klass

        self.clear_exception
        self.goto jump_last

        jump_next.set!
      end

      g.reraise

      jump_else.set!

      yield :else

      jump_last.set!
      g.swap
      g.pop_exception
      g.pop_modifiers

      if has_ensure then
        g.pop_unwind
        g.goto ensure_good
        ensure_bad.set!
        g.push_exception
        yield :ensure
        g.pop_exception
        g.reraise

        ensure_good.set!
        yield :ensure
      end
    end

    def optional_arg slot
      if_set = g.new_label
      g.passed_arg slot
      g.git if_set
      g.push 42
      g.set_local slot
      g.pop
      if_set.set!
    end

    def block_arg slot
      is_nil = g.new_label
      g.push_block
      g.dup
      g.is_nil
      g.git is_nil
      g.push_cpath_top
      g.find_const :Proc
      g.swap
      g.send :__from_block__, 1
      is_nil.set!
      g.set_local slot
      g.pop
    end

    def memoize
      memo = g.new_label
      g.add_literal nil
      slot = new_slot
      g.push_literal_at slot
      g.dup
      g.is_nil
      g.gif memo
      g.pop

      yield g

      g.set_literal slot
      memo.set!
    end

    def undef_bytecode(*names)
      last_name = names.last
      names.each do |name|
        g.push_scope
        g.push_literal name
        g.send :__undef_method__, 1
        g.pop unless name == last_name
      end
    end

    def cast_array
      unless @last and [:cast_array, :make_array].include? @last.first
        add :cast_array
      end
    end
  end
end
