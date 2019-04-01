export getblock, nbit_used, nbit_simulated, nrepeat, chem2circuit, QuantumMPS
export state_exact, fidelity_exact
export gensample

"""
    QuantumMPS{RT}

Members:
    `nbit_measure`, number of qubits measured in a single iteration, or physical qubits.
    `nbit_virtual`, number of virtual qubits to represent the virtual bond dimension in quantum MPS.
    `circuit`, the circuit structure (measurements are not included).
    `initial_reg`, the initial state (GPUReg or a regular one), always prepaired in |0>.
    `nbit_ancilla`, number of ancilla qubits.
"""
struct QuantumMPS{RT}
    nbit_measure::Int
    nbit_virtual::Int
    nbit_ancilla::Int

    circuit::AbstractBlock
    initial_reg::RT

    input_state::Vector{Int}
end

getblock(chem::QuantumMPS, i::Int) = chem.circuit[i]
nrepeat(chem::QuantumMPS) = length(chem.circuit)
nbit_used(chem::QuantumMPS) = nqubits(chem.circuit[1])
nbit_simulated(chem::QuantumMPS) = chem.nbit_measure*nrepeat(chem) + chem.nbit_virtual

"""convert a chem circuit to a circuit with no reuse"""
function chem2circuit(tnchem)
    nbit = nbit_simulated(tnchem) + tnchem.nbit_ancilla
    nm = tnchem.nbit_measure
    nv = tnchem.nbit_virtual + tnchem.nbit_ancilla
    c = chain(nbit)
    for (i, blk) in enumerate(tnchem.circuit)
        push!(c, concentrate(nbit, blk, [(i-1)*nm+1:i*nm..., nbit-nv+1:nbit...]))
    end
    c
end

function state_exact(chem::QuantumMPS)
    circuit = chem2circuit(chem)
    if chem.nbit_ancilla == 0
        return product_state(nqubits(circuit), chem.input_state|>Yao.Intrinsics.packbits) |> circuit
    else
        nbit = nqubits(circuit)
        product_state(nbit, chem.input_state|>Yao.Intrinsics.packbits) |> circuit |> focus!((1:nbit-chem.nbit_ancilla)...) |> remove_env!
    end
end

function remove_env!(reg::DefaultRegister)
    reg.state = dropdims(sum(reg |> rank3, dims=2), dims=2)
    reg
end

function fidelity_exact(chem::QuantumMPS, ground_state::AbstractRegister)
    fidelity(ground_state, state_exact(chem))
end

function gensample(chem::QuantumMPS, pauli::PauliGate)
    input_state = chem.input_state
    reg = chem.initial_reg |> copy
    nv = chem.nbit_virtual + chem.nbit_ancilla
    nrep = nrepeat(chem)
    T = datatype(chem.initial_reg)

    op = eigen!(pauli |> mat |>Matrix)
    rotor = put(nv+1, 1=>matrixgate(T.(op.vectors' |> Matrix)))
    local res = similar(reg |> state, Int, nbatch(reg), nbit_simulated(chem))
    for i = nrep+1:nrep+nv
        input_state[i] == 1 && apply!(reg, put(nv+1, (i-nrep+1)=>X))
    end
    input_state[1] == 1 && apply!(reg, put(nv+1, 1=>X))
    for i=1:nrep
        reg |> getblock(chem, i)
        if i!=nrep
            reg |> rotor
            @inbounds res[:,i] = 1 .- 2 .* measure_reset!(reg, 1, val=input_state[i+1])
        end
    end
    for i=1:nv+1-chem.nbit_ancilla
        reg |> rotor
        @inbounds res[:,i+nrep-1] = 1 .- 2 .* measure_remove!(reg, 1)
    end
    res
end

"""
convert a chem circuit (with reset) to MPS

qubits are arranged in measure order.
"""
function chem2tebd(chem)
    Nm = 2
    Nv = 1<<chem.nbit_virtual
    circuit = chem.circuit
    tensors = MPSTensor{ComplexF64}[]
    for (i, blk) in enumerate(circuit)
        if i==1
            ts = permutedims(view(reshape(mat(blk) |> Matrix, Nm, Nv, Nm, Nv),:,:,1,1:1), (3,1,2))
        else
            ts = permutedims(view(reshape(mat(blk) |> Matrix, Nm, Nv, Nm, Nv),:,:,1,:), (3,1,2))
        end
        push!(tensors, ts)
    end
    # add projectors
    for i=1:chem.nbit_virtual
        N = size(tensors[end], 3)
        ts = reshape(Matrix{ComplexF64}(I, N, N), N, 2, N÷2)
        push!(tensors, ts)
    end
    MPS(tensors, nrepeat(chem))
end
