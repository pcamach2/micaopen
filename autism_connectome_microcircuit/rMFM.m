%% Basic settings
clear;clc; close all

%%% Add path
ProcPath = '/data/mica2/boyong/43_MFM_ASD/0.code/open_code';
addpath(genpath(ProcPath));

%%% Basic settings
NumROI = 200;           % Number of ROIs
fold_k = 5;             % Cross-validation folds
N_core = 12;            % Number of CPU cores for calculation
EstimationMaxStep = 64; % Number of estimation step
NumSimul = 100;         % Number of simulation
TR = 2;                 % Repetition time
TE = 0.02;              % Echo time

%% Parameter estimation
GrpName = {'ASD', 'CTL'};
for gp = 1:2
    for cv = 1:fold_K
        disp(strcat(['### ',GrpName{gp},' -- CV = ',int2str(cv)]));
        
        poolobj = gcp('nocreate');
        delete(poolobj);
        
        disp(['number of CPU cores used:' num2str(N_core)])
        disp(['maximum estimation steps:' num2str(EstimationMaxStep)])
        %----------------------------------------------------------
        
        %----------------------------------------------------------
        % prepare the empirical data
        %load FC and DC
        %%%%%%%%% LOAD YOUR OWN FC AND DC %%%%%%%%%
        % FCZ_tot_struc
        %              .train
        %                    .cv1~5: # of ROI x # of ROI x # of training subjects
        %              .test
        %                    .cv1~5: # of ROI x # of ROI x # of training subjects
        % DC_tot_struc             : SAME AS ABOVE
        % DC_EL_tot_struc          : SAME AS ABOVE
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        
        exp_tmp = ['FCZ_tot = FCZ_tot_struc.train.cv',int2str(cv),';'];
        eval(exp_tmp);
        exp_tmp = ['DC_tot = DC_tot_struc.train.cv',int2str(cv),';'];
        eval(exp_tmp);
        exp_tmp = ['DC_EL_tot = DC_EL_tot_struc.train.cv',int2str(cv),';'];
        eval(exp_tmp);
        
        % group representative  matrix
        FC = mean(FCZ_tot,3);
        
        EL = DC_EL_tot;
        EL(EL==0) = nan; % edgeLengths_40M.txt
        el_group = nanmean(EL(1:NumROI,1:NumROI,:),3);
        el_group(isnan(el_group)) = 0;
        el_group(1:size(el_group)+1:end) = 0;
        hemiid = [ones(1, NumROI/2) ones(1, NumROI/2)*2]';
        temp = DC_tot;
        G = fcn_distance_dependent_threshold(temp, el_group, hemiid, 1);
        DC = G .* nanmean(temp,3); % weight by group average
                
        %scaling the DC
        DC = DC./max(max(DC)).*0.2;
        
        %find out number of brain regions
        NumC = length(diag(DC));
        
        FC_mask = tril(ones(size(FC,1),size(FC,1)),0);
        y = FC(~FC_mask); %use the elements above the maiin diagnal, y becomes a vector {samples x 1}
        n = 1;            %only one FC
        T = length(y);    %samples of FC
        nT = n*T;         %number of data samples
        
        %-----------------------------------------------------------
        
        %-----------------------------------------------------------
        % prepare the model parameters
        % set up prior for G(globle scaling of DC), w(self-connection strength/excitatory),Sigma(noise level),Io(background input)
        p = 2*NumC + 2; %number of estimated parameter
        Prior_E = zeros(p,1);
        
        %basic value / expectation value
        Prior_E(1:NumC) = 0.5;%w
        Prior_E(NumC+1:NumC+NumC) = 0.3;%I0
        Prior_E(2*NumC+1) = 1;%G
        Prior_E(2*NumC+2) = 0.001;%sigma
        
        %Prior for Re-Parameter A,  Parameter_model = Prior_E.*exp(A), A~Normal(E=0,C)
        A_Prior_C = 1/4*ones(1,p);%variance for parameter
        A_Prior_C = diag(A_Prior_C);
        A_Prior_E = zeros(p,1);
        invPrior_C = inv(A_Prior_C);
        
        %==========================
        %initial Parameter
        %==========================
        Para_E = Prior_E;
        Para_E_new = Para_E;
        
        %re-paramter of Para_E
        A = log(Para_E./Prior_E);
        %----------------------------------
        
        %-----------------------------------------------------------
        % begin estimation
        
        step = 1; %counter
        
        % setup save vectors
        CC_check_step = zeros(1,EstimationMaxStep+1);     %save the fitting criterion, here is the goodness of fit, same as rrr below
        lembda_step_save = zeros(n,EstimationMaxStep);    %save the Ce
        rrr = zeros(1,EstimationMaxStep);                 %save the goodness of fit
        rrr_z  = zeros(1,EstimationMaxStep);              %save the correlation between emprical FC and simulated FC, z-transfered
        Para_E_step_save = zeros(p,EstimationMaxStep);    %save the estimated parameter
        
        %setup the cluster
        cluster = parcluster('local');
        cluster.JobStorageLocation = ProcPath;
        parpool(cluster,N_core);
        
        %--------------------------------------start whole loop, begin estimation
        while (step <= EstimationMaxStep)
            %---------------------
            
            
            step
            fix(clock)
            
            Para_E_step = Para_E;
            
            
            if step == 1
                load(fullfile(HeadPath,'saved_original_random_generator.mat'),'Nstate') %use the same randon generator in our paper
            else
                Nstate = rng;
            end
            
            
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            %caculation h_output {nT x 1}
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            
            funcP = @(Para_E) CBIG_MFMem_rfMRI_nsolver_eul_sto(Para_E,Prior_E,DC,y,FC_mask,Nstate,14.4,TR,0,TE);
            funcA = @(A) CBIG_MFMem_rfMRI_nsolver_eul_sto(A,Prior_E,DC,y,FC_mask,Nstate,14.4,TR,1,TE);
            
            [h_output, CC_check] = funcP(Para_E);  %CC_check: cross-correlation check of two FCs
            %h_output: output of model, entries above the main diagonal of the simulated FC, z-transfered
            
            
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            %caculation of Jacobian, JF, JK, {nT x p }
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            JF = zeros(nT,p);
            JK = JF;
            JFK = [JF JK];
            
            %begin parallel computing to caculate the Jacobian
            %--------------------------------------------------------------------
            parfor i = 1:2*p
                if i <= p
                    disp('running JF')
                    JFK(:,i) = CBIG_MFMem_rfMRI_diff_P1(funcA,A,h_output,i); % {nT x p}
                else
                    disp('running Jk')
                    JFK(:,i) = CBIG_MFMem_rfMRI_diff_PC1(funcA,A,i-p);
                end
            end
            %--------------------------------------------------------------------
            %end parallel computiong
            
            JF  = JFK(:,1:p); % {nT x p}
            JK  = JFK(:,p+1:2*p);
            
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            %caculation of r, difference between emprical data y and model output h_output
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            
            r = y - h_output; % {n*T x 1}
            
            
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            %prepare parallel computing of EM-algorithm
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            A_old = A;
            
            A_FDK = zeros(p,2);
            h_output_FDK = zeros(nT,2);
            r_FDK = r;
            lembda_FDK = zeros(n,2);
            
            dlddpara_FDK = zeros(p,p,2);
            dldpara_FDK = zeros(p,2);
            
            
            LM_reg_on = [1 1]; %switcher of Levenberg-Marquardt regulation, started if correlation between FCs > 0.4
            
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            %Estimation using Gauss-Newton and EM begin here, cautions by modification
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            
            %start parallel computing of EM
            %----------------------------------------------------------------------
            parfor ppi= 1:2                  %begin parfor caculation
                
                if ppi == 1   %first ,J = JF
                    J = JF;
                    r = r_FDK;
                    disp('begin J = FD');
                else
                    J = JK;
                    r = r_FDK;
                    disp('begin J = K');
                end
                
                % prepare lembda for lembda, Ce
                lembda = -3*ones(n,1);
                DiagCe = ones(1,nT);  %only have main diagonal entries
                for i = 1:n
                    DiagCe(T*(i-1)+1:T*(i-1)+T) = exp(lembda(i));
                end
                %inv(Ce):
                inv_DiagCe = DiagCe.^-1;  %try to only use diagonal element
                
                % preparation g, H, for g & H, see [2]
                g = zeros(n,1); %initialization
                H = zeros(n,n); %initialization
                
                
                for mi = 1:16  %<-------------------------------begin M-step loop
                    
                    %          disp('m step:')
                    %          disp(mi)
                    
                    %-------------------------------------------------------
                    %
                    % P = inv(Ce) - inv(Ce) * J * pinv(J'*inv(Ce)*J) * J' * inv(Ce); {nT x p}
                    %
                    % see [2,3]
                    %-------------------------------------------------------
                    
                    %first computing: pinv(J'*inv(Ce)*J)
                    inv_JinvCeJ = zeros(p,nT);
                    %step1: J'*inv(Ce)
                    for i = 1:p
                        inv_JinvCeJ(i,:) = bsxfun(@times,J(:,i)', inv_DiagCe);
                    end
                    %step2: J'*inv(Ce)*J
                    inv_JinvCeJ = inv_JinvCeJ*J;
                    %step3: pinv(J'*inv(Ce)*J)
                    inv_JinvCeJ = pinv(inv_JinvCeJ);
                    
                    %now computing:  %inv(Ce) * J * inv_JinvCeJ * J' * invCe
                    P = zeros(nT,p);
                    %step1: inv(Ce) * J
                    for i = 1:p
                        P(:,i) = bsxfun(@times, J(:,i), inv_DiagCe');
                    end
                    %step2: (inv(Ce) * J) * inv_JinvCeJ * J'
                    P = P*inv_JinvCeJ*J';
                    %step3:  -(inv(Ce) * J * inv_JinvCeJ * J') * inv(Ce)
                    for i = 1:nT
                        P(:,i) = bsxfun(@times, P(:,i), -inv_DiagCe');
                    end
                    %step4: invCe - (inv(Ce) * J * inv_JinvCeJ * J' * inv(Ce) )
                    P(1:(nT+1):nT*nT) = bsxfun(@plus, diag(P)',inv_DiagCe);
                    
                    P = single(P);   %memory trade off
                    
                    
                    %-------------------------------------------------------
                    %
                    % g(i) = -0.5*trace(P*exp(lembda(i))*Q(i))+0.5*r'*invCe*exp(lembda(i))*Q(i)*invCe*r;  {n x 1}
                    %                         d  Ce
                    % exp(lembda(i))*Q(i) =  -- ---
                    %                         d  lembda(i)
                    %
                    % see [2,3]
                    %-------------------------------------------------------
                    
                    for i = 1:n
                        %step1: 0.5*r'*invCe*exp(lembda(i))*Q(i)
                        g(i) = -0.5*exp(lembda(i))*trace(P(T*(i-1)+1:T*(i-1)+T,T*(i-1)+1:T*(i-1)+T));
                        %step2: (0.5*r'*invCe*exp(lembda(i))*Q(i))*invCe*r
                        g_rest = 0.5*bsxfun(@times,r',inv_DiagCe)*exp(lembda(i))*CBIG_MFMem_rfMRI_matrixQ(i,n,T); %CBIG_MFMem_rfMRI_matrixQ is used to caculate Q(i)
                        g_rest = bsxfun(@times,g_rest,inv_DiagCe)*r;
                        %step3:
                        g(i) = g(i) + g_rest;
                    end
                    
                    %-------------------------------------------------------
                    %
                    %H(i,j) = 0.5*trace(P*exp(lembda(i))*Q(i)*P*exp(lembda(j))*Q(j)); {n x n}
                    %
                    % see [2,3]
                    %-------------------------------------------------------
                    
                    for i = 1:n
                        for j = 1:n
                            Pij = P(T*(i-1)+1:T*(i-1)+T,T*(j-1)+1:T*(j-1)+T);
                            Pji = P(T*(j-1)+1:T*(j-1)+T,T*(i-1)+1:T*(i-1)+T);
                            H(i,j) = 0.5*exp(lembda(i))*exp(lembda(j))*CBIG_MFMem_rfMRI_Trace_AXB(Pij,Pji);
                        end
                    end
                    
                    %clear P Pij Pji
                    P = [];
                    Pij = [];
                    Pji = [];
                    
                    %update lembda
                    d_lembda = H\g; % delta lembda
                    
                    lembda = lembda + d_lembda;
                    
                    for i = 1:n
                        if lembda(i) >= 0
                            lembda(i) = min(lembda(i), 10);
                        else
                            lembda(i) = max(lembda(i), -10);
                        end
                    end
                    
                    %--------------------------------------------------------------------------
                    
                    
                    
                    %update Ce for E-step
                    DiagCe = ones(1,nT);
                    for i = 1:n
                        DiagCe(T*(i-1)+1:T*(i-1)+T) = exp(lembda(i));
                    end
                    inv_DiagCe = DiagCe.^-1;
                    
                    %abort criterium of m-step
                    if max(abs(d_lembda)) < 1e-2, break, end
                    
                end
                %<-------------------end M-step loop %----------------------------------
                
                %display lembda
                lembda
                lembda_FDK(:,ppi) = lembda;
                
                
                %----------------E-step-----------------------------------------------
                
                %-------------------------------------------------------------------
                %
                %dldpara:   1st. derivative, {p x 1}, used in Gauss-Newton search
                %           dldpara = J'*inv(Ce)*r + inv(Prior_C)*(A_Prior_E - A);
                %
                %dlddpara:  inv, negativ, 2nd. derivative, {p x p}, used in Gauss-Newton search
                %           dlddpara = (J'*inv(Ce)*J + inv(Prior_C));
                %
                %see [2,3]
                %-------------------------------------------------------------------
                
                JinvCe = zeros(p,nT); %J'invCe
                for i = 1:p
                    JinvCe(i,:) = bsxfun(@times,J(:,i)', inv_DiagCe);% J'%invCe <----- p x nT
                end
                
                
                
                dlddpara = (JinvCe*J + invPrior_C); % inv, negativ, von 2nd. derivative {p x p}
                
                dldpara = JinvCe*r + invPrior_C*(A_Prior_E - A); % 1st. derivative, {p x 1}
                
                JinvCe = []; %save the memory
                
                
                d_A = dlddpara\dldpara;
                A_FDK(:,ppi) = A + d_A; %newton-gauss, fisher scoring, update Para_E
                Para_E_new = exp(A_FDK(:,ppi)).*Prior_E;
                
                dPara_E_new = abs(Para_E_new - Para_E);
                
                if any(bsxfun(@ge,dPara_E_new,0.5)) %paramter should not improve too much
                    d_A = (dlddpara+10*diag(diag(dlddpara)))\dldpara;
                    disp('using reg = 10')
                    A_FDK(:,ppi) = A + d_A; %newton-gauss, fisher scoring, update Para_E
                    Para_E_new = exp(A_FDK(:,ppi)).*Prior_E;
                    LM_reg_on(ppi) = 0;
                end
                
                [h_output_FDK(:,ppi), CC_check_FDK(:,ppi)] = funcP(Para_E_new);
                r = y - h_output_FDK(:,ppi);
                
                dlddpara_FDK(:,:,ppi) = dlddpara;
                dldpara_FDK(:,ppi) = dldpara;
                
                
            end
            %<---------------------------------------------------------------------
            %end parallel computiong
            
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            %comparision the Fitting improvement between using JF and JK, choose the better one
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            
            
            % comprision JF and JK------------------------------------------------------
            F_comparison = CC_check_FDK(:,1);
            K_comparison = CC_check_FDK(:,2);
            
            if F_comparison >= K_comparison
                A = A_FDK(:,1);
                h_output = h_output_FDK(:,1);
                CC_check_step(step+1) = CC_check_FDK(:,1);
                lembda_step_save(:,step) = lembda_FDK(:,1);
                dlddpara = dlddpara_FDK(:,:,1);
                dldpara = dldpara_FDK(:,1);
                
                if CC_check_step(step+1) > 0.4   %Levenberg-Marquardt regulation, started if correlation between FCs > 0.4
                    LM_on = LM_reg_on(1);
                else
                    LM_on = 0;
                end
                
                disp('choose FD')
                
            else
                A = A_FDK(:,2);
                h_output = h_output_FDK(:,2);
                CC_check_step(step+1) = CC_check_FDK(:,2);
                lembda_step_save(:,step) = lembda_FDK(:,2);
                dlddpara = dlddpara_FDK(:,:,2);
                dldpara = dldpara_FDK(:,2);
                
                if CC_check_step(step+1) > 0.4 %Levenberg-Marquardt regulation, started if correlation between FCs > 0.4
                    LM_on = LM_reg_on(2);
                else
                    LM_on = 0;
                end
                
                
                disp('choose Komplex')
            end
            
            % -----------------End comparision------------------------------------------------
            
            
            
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            %now adding levenberg-Maquadrat
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            if LM_on == 1
                
                disp('begin Levenberg')
                
                lembda = lembda_step_save(:,step);
                
                DiagCe = ones(1,nT);
                for i = 1:n
                    DiagCe(T*(i-1)+1:T*(i-1)+T) = exp(lembda(i));
                end
                inv_DiagCe = DiagCe.^-1;  %try to only use diagonal element
                
                %regulation value table
                reg_reg = [0,1,10,100];
                Nreg = length(reg_reg);
                
                A_reg = zeros(p,Nreg);
                h_output_reg = zeros(nT,Nreg);
                lembda_reg = zeros(n,Nreg);
                
                %transfer results for reg = 0
                A_reg(:,1) = A;
                h_output_reg(:,1) = h_output;
                CC_check_reg(:,1) = CC_check_step(step+1);
                
                %<--------begin parallel computing-------------------------------
                parfor ppi = 2:Nreg
                    
                    
                    reg = reg_reg(ppi);
                    A = A_old;
                    
                    d_A = (dlddpara+reg*diag(diag(dlddpara)))\dldpara; %LM
                    A_reg(:,ppi) = A + d_A; %newton-gauss, fisher scoring, update Para_E
                    Para_E_new = exp(A_reg(:,ppi)).*Prior_E;
                    
                    [h_output_reg(:,ppi), CC_check_reg(:,ppi)] = funcP(Para_E_new);
                    r = y - h_output_reg(:,ppi);
                    
                end
                %<--------------------end parallel computing------------------------------
                
                
                clear DiagCe inv_DiagCe
                
                T_comparision = CC_check_reg;
                [CC_check_step_save(step+1),T_comparision_indx] = max(T_comparision);
                
                disp(['chosen reg is: ' num2str(reg_reg(T_comparision_indx))]);
                A = A_reg(:,T_comparision_indx);
                h_output = h_output_reg(:,T_comparision_indx);
                CC_check_step(step+1) = CC_check_reg(:,T_comparision_indx);
                
            end
            %--------------------------------------------------------------------------------
            
            
            
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            %update results, check abbort criterium
            %<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
            
            Para_E = exp(A).*Prior_E;
            d_Para_E = Para_E - Para_E_step;
            
            dN = sqrt(sum(d_Para_E.^2))
            
            rrr(step) = 1-(var(y-h_output)/var(y));%goodness of fit
            %             rrr_z(step)  = corr(atanh(h_output),atanh(y)); %correlation between 2 FCs
            rrr_z(step)  = corr(h_output,y); %correlation between 2 FCs
            
            Para_E_step_save(:,step) = Para_E;
            
            disp(['goodness of fitting = ' num2str(rrr(step))])
            disp(['goodness of fitting correlation = ' num2str(rrr_z(step))])
            
            
            %Abort criterium of total estimation
            if ((step>5)&&(rrr(step) >= 0.99 || (dN < 1e-5 && rrr_z(step) > 0.5) ) ), break, end
%                 if ((step>5)&&(rrr_z(step)-rrr_z(step-1)<=-0.10)),break,end   % stop if we find a bifucation edge, it should be a good solution (Deco et al., 2013)
            if ((step>5)&&(rrr_z(step)-rrr_z(step-1)<=-0.40)),break,end   % stop if we find a bifucation edge, it should be a good solution (Deco et al., 2013)
            
            step = step + 1; %counter
            
        end
        %<-----------------------------------------End while loop, End estimation ---------
        
        %--------------------------------------------------------------------------
        % End estimation, save result
        
        %find the best results
        [rrr_z_max,indx_max] = max(rrr_z);
        Para_E = Para_E_step_save(:,indx_max);
        
        disp(rrr_z_max)
        disp(indx_max)
        disp(Para_E)
        
        Estimated_parameter.rrr_z=rrr_z;
        Estimated_parameter.rrr_z_max=rrr_z_max;
        Estimated_parameter.indx_max = indx_max;
        Estimated_parameter.Para_E=Para_E;
        save(strcat(ProcPath,'/rMFM/Estimated_parameter_',GrpName{gp},'_cv',int2str(cv),'.mat'),'Estimated_parameter');
        
        
        poolobj = gcp('nocreate');
        delete(poolobj);
    end
end

%% Simulation
GrpName = {'ASD', 'CTL'};
traintest = {'train','test'};
for trate = 1:2
    for gp = 1:2
        for cv = 1:fold_K
            disp(strcat(['### ',traintest{trate},': ',GrpName{gp},' -- CV = ',int2str(cv)]));
            
            % load model parameters
            load(strcat(ProcPath,'/rMFM/Estimated_parameter_',GrpName{gp},'_cv',int2str(cv),'.mat'));
            Para_E = Estimated_parameter.Para_E;
            
            %load FC and DC
            %%%%%%%%% LOAD YOUR OWN FC AND DC %%%%%%%%%
            % FCZ_tot_struc
            %              .train
            %                    .cv1~5: # of ROI x # of ROI x # of training subjects
            %              .test
            %                    .cv1~5: # of ROI x # of ROI x # of training subjects
            % DC_tot_struc             : SAME AS ABOVE
            % DC_EL_tot_struc          : SAME AS ABOVE
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            
            exp_tmp = ['FCZ_tot = FCZ_tot_struc.',traintest{trate},'.cv',int2str(cv),';'];
            eval(exp_tmp);
            exp_tmp = ['DC_tot = DC_tot_struc.',traintest{trate},'.cv',int2str(cv),';'];
            eval(exp_tmp);
            exp_tmp = ['DC_EL_tot = DC_EL_tot_struc.',traintest{trate},'.cv',int2str(cv),';'];
            eval(exp_tmp);
            
            % group representative structural matrix
            FC = mean(FCZ_tot,3);
            
            EL = DC_EL_tot;
            EL(EL==0) = nan; % edgeLengths_40M.txt
            el_group = nanmean(EL(1:NumROI,1:NumROI,:),3);
            el_group(isnan(el_group)) = 0;
            el_group(1:size(el_group)+1:end) = 0;
            hemiid = [ones(1, NumROI/2) ones(1, NumROI/2)*2]';
            temp = DC_tot;
            G = fcn_distance_dependent_threshold(temp, el_group, hemiid, 1);
            DC = G .* nanmean(temp,3); % weight by group average
            
            %scaling the DC
            DC = DC./max(max(DC)).*0.2;
                        
            % prepare FC: use the entries above main diagonal
            FC_mask = tril(ones(size(FC,1),size(FC,1)),0);
            y = FC(~FC_mask);
            %--------------------------------------------------------------------
            
            %--------------------------------------------------------------------
            % begin simulation
            funcP = @(Para_E,Nstate) CBIG_MFMem_rfMRI_nsolver_eul_sto_resLH(Para_E,DC,y,FC_mask,Nstate,14.4,TR,0,TE);
            
            for i = 1:NumSimul
                
                disp(['Sim:' num2str(i)]);
                
                Nstate = rng;
                [h_output(i,:), CC_check(i)] = funcP(Para_E,Nstate);
                
                disp(CC_check(i));
                
            end
            %--------------------------------------------------------------------
            
            %--------------------------------------------------------------------
            % plot result
            %     set(figure,'Position',[100 130 600 400],'Color','w')
            %
            %     plot([1:numSimulation],CC_check,'ko-','markerfacecolor','k')
            %     xlabel('simulation number','FontSize',9)
            %     ylabel('Similarity','FontSize',9)
            %--------------------------------------------------------------------
            
            
            %--------------------------------------------------------------------
            % make simulated FC
            [val, idx] = max(CC_check);
            
            FC_mask = tril(ones(NumROI,NumROI),0);
            FC_simR = zeros(NumROI,NumROI);
            FC_simR(~FC_mask) = h_output(idx,:);
            FC_simR = FC_simR + FC_simR';
            FC_simZ = atanh(FC_simR);
            %--------------------------------------------------------------------
            
            %--------------------------------------------------------------------
            % save result
            saved_date = fix(clock);
            
            save( strcat([ProcPath '/rMFM/',int2str(NumSimul),'simulation_',GrpName{gp},'_',traintest{trate},'_cv',int2str(cv),'.mat']),'CC_check', 'h_output', 'FC_simZ');
            %--------------------------------------------------------------------
        end
    end
end
